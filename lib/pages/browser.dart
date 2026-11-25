import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
// ImageFilter is used only by the status-bar frost blur, currently
// commented out (see _buildAddressBar). Kept so
// restoring the blur needs no import change.
// ignore: unused_import
import 'dart:ui' show ImageFilter;
import 'package:publicos_core/publicos_core.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:publicos_client/components/star_button.dart';
import 'package:publicos_client/components/feeds/add_to_lists_sheet.dart';
import 'package:publicos_client/components/glass_context_menu.dart';
import 'package:publicos_client/components/nft_info_dialog.dart';
import 'package:publicos_client/components/nft_banner.dart';
import 'package:publicos_client/components/feeds/feed_source.dart';
import 'package:publicos_client/components/feeds/channel_signin_dialogs.dart';
import 'package:publicos_client/components/feeds/posts_list.dart';
import 'package:publicos_client/widgets/content_metrics_listener.dart';
import 'package:publicos_client/widgets/image_overlay.dart'; // Ensure ImageOverlay is imported
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/components/chat_no_key_state.dart';
import 'package:publicos_client/components/keychain/keychain_sheet.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';
// import 'package:go_router/go_router.dart'; // No longer used
import 'package:publicos_client/app_routes.dart'; // Import for ContactIdentifierType and BrowserTab
import 'package:publicos_client/components/browser/animated_banner.dart';
import 'package:publicos_client/components/glass_contact_icon.dart';
import 'package:publicos_client/pages/chat_screen.dart';
import 'package:publicos_client/pages/contact_settings_screen.dart';
import 'package:publicos_client/pages/profile_page.dart';
import 'package:publicos_client/pages/profile_qr_page.dart';
import 'package:wallet/wallet.dart';
import 'package:webview_flutter/webview_flutter.dart'; // Import for WebView
import 'package:zero_cached_image/zero_cached_image.dart'; // For ZeroCachedImage
import 'package:publicos_client/components/profile/edit_profile_image_sheet.dart'; // For EditProfileImageSheet
// Added for Record
import 'package:publicos_client/components/profile/manage_profile_tabs_sheet.dart'; // Added for ManageProfileTabsSheet
import 'package:publicos_client/components/profile/edit_profile_background_sheet.dart';
import 'package:publicos_client/components/profile/constellation_canvas.dart';
import 'package:publicos_client/components/profile/profile_art_layout.dart';
import 'package:publicos_client/components/browser/action_slot.dart';
import 'package:publicos_client/components/org_management/group_voting_view.dart'; // Import for GroupVotingView
import 'package:publicos_client/components/profile/tab_icon_widget.dart'; // For tab icons with favicon/RSS images
import 'package:publicos_client/components/browser/tab_selection_dropdown.dart';
import 'package:publicos_client/components/browser/tab_selection_dropdown_v2.dart';
// For app registry apps
// For app registry operations
import 'package:publicos_web3_bridge/publicos_web3_bridge.dart'
    show ChainRegistry; // the running page's chain, for the address-bar badge
import 'package:publicos_client/components/browser/publicos_webview.dart'; // Web3-enabled WebView wrapper
import 'package:publicos_client/components/browser/web_key_indicator.dart'; // Which key the webview hands the page
import 'package:publicos_client/components/sync_indicator.dart'; // For chain sync indicator
import 'package:publicos_client/providers/theme_provider.dart';
import 'package:publicos_client/router.dart';
import 'package:publicos_client/widgets/fullscreen_overlay.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/components/pixel_rain_loading_label.dart';
import 'package:publicos_client/components/flag_sheet.dart';

// Define the content widgets for each tab
// These could be in separate files if they grow complex,
// but for now, keeping them as methods within the BrowserState
// aligns with a more monolithic approach.

class Browser extends StatefulWidget {
  final ContactIdentifierType identifierType;
  final String identifier;

  /// The :type segment of /publicosAddress/:address/:type/:key — one of
  /// {profile, settings, management, tab, chat, app}. Null lands on profile
  /// (or chat for inboxId / conversationTopic identifiers).
  final String? routeType;

  /// The :key segment — record key (tab), inbox label (chat), or app name
  /// (app). Resolved against the loaded contact by the per-type handlers.
  final String? routeKey;

  final String? initialUrl; // Optional URL for the webview tab
  final String? inboxId; // Optional inboxId for chat tab (the /inboxId route)

  /// In-app deep-link payload carried via go_router `extra` — the destination
  /// content the caller already held (a tab [Record] or an [AppBookmark]), so
  /// the target tab mounts on frame 1 instead of flashing the profile while the
  /// :key resolves. Null on cold/external links, which resolve the key instead.
  final Object? landingPayload;

  /// Optional composer pre-fill for a chat landing, carried from a deep-link
  /// `?message=` query param. Seeded once on mount; never overrides a saved draft.
  final String? messageDraft;

  const Browser({
    super.key,
    required this.identifierType,
    required this.identifier,
    this.routeType,
    this.routeKey,
    this.initialUrl,
    this.inboxId,
    this.landingPayload,
    this.messageDraft,
  });

  @override
  State<Browser> createState() => _BrowserState();

  /// Lands an inbound `/publicosAddress/<address>[/<type>[/<key>]]` link on the
  /// Browser already on screen for that address, as if the user had picked the
  /// tab — instead of pushing a second Browser over it. Our own card links
  /// round-trip through the OS (`launchUrl` → app link → `onDeepLink`), so a
  /// card pointing at the profile you are on would otherwise stack a copy of it.
  /// Returns false when no visible Browser shows [address], or for a [type]
  /// this does not handle (settings / management), so the caller pushes.
  static bool landInVisibleBrowser({
    required String address,
    String? type,
    String? key,
  }) {
    for (final state in _BrowserState._live) {
      if (state._showsAddressOnTop(address)) {
        return state._landInPlace(type, key);
      }
    }
    return false;
  }
}

class _BrowserState extends State<Browser> with TickerProviderStateMixin {
  Contact? _contact;
  bool _isLoading = true;
  bool _selfProfile = false;
  String? _error;
  late BrowserTab _currentTab;

  // Lagged mirror of _currentTab. Tab-specific right-side icons (QR/Share
  // on profile, bookmark on app, follow/add-to-list on rss) render only
  // when _currentTab AND _displayedTab agree. _currentTab flips
  // immediately on switch (so outgoing icons vanish in lockstep with the
  // old tab leaving), and _displayedTab catches up 200ms later (so
  // incoming icons appear AFTER the path AnimatedSwitcher's exit
  // animation has freed the slot it was holding via its default
  // Stack-max layout). Without this lag, switching M→P stacks the
  // outgoing /Management width on the left with the new QR+Share width
  // on the right, squeezing displayName to ellipsis for 200ms.
  late BrowserTab _displayedTab;
  BrowserTab? _pendingDisplayedTab;
  Timer? _displayedTabTimer;

  // Back navigation: tracks whether the user has switched tabs since landing.
  // On back: if true → replay _landingTabItem via _handleTabSelection; if false → dismiss.
  bool _hasNavigatedAway = false;
  TabItem? _landingTabItem; // Captured once the landing tab is fully resolved

  // In-webview history back-nav. The webview tabs (BrowserTab.webview /
  // BrowserTab.app) embed a PublicOSWebView. _webViewController is the handle
  // for goBack(); _webViewCanGoBack is a synchronously-readable mirror of the
  // controller's canGoBack(), refreshed on every navigation edge. Together they
  // drive the back chevron (both platforms) and the Android system-back
  // interception in the PopScope below. iOS swipe is left native.
  WebViewController? _webViewController;
  bool _webViewCanGoBack = false;

  // True when the current tab embeds a webview that has in-page history.
  bool get _webViewHasHistory =>
      (_currentTab == BrowserTab.webview || _currentTab == BrowserTab.app) &&
      _webViewCanGoBack;

  // Tier 1 / canPop only intercept the back gesture on Android; the iOS
  // edge-swipe stays native (in-webview back on iOS is the chevron).
  bool get _androidWebViewBack => _webViewHasHistory && Platform.isAndroid;

  // Chain sync state
  bool _isSyncingFromChain = false;
  bool _chainSyncFailed = false;
  String? _currentWebViewUrl; // Track the current webview URL

  /// Whether the displayed webview/app page holds any grant. Driven by
  /// PublicOSWebView.onConnectionChanged (a connect event); the web-key
  /// indicator renders as a pure function of this. Because exactly one webview
  /// is ever mounted, this single flag is the whole tab-connection model — no
  /// per-tab registry needed.
  bool _webConnected = false;

  /// The running page's own [ChainRegistry], handed over by the webview, and
  /// the chain it currently reads on. Held only so the address bar can show
  /// the chain and move it: the registry belongs to the webview and dies with
  /// it, so both are cleared when a new page is built (the webview is keyed by
  /// URL, which is what makes "PublicOS on every fresh page" true rather than
  /// a remembered setting).
  ChainRegistry? _webChains;
  String? _webChainId;

  /// Bumped whenever the key indicator's picker changes this site's grants.
  /// Handed to the webview, whose `didUpdateWidget` re-reads the set and tells
  /// the running page. A revision rather than the old `webSelectedKey` label,
  /// because switching the preferred key no longer changes what a site may see
  /// — the permission did (browser_key_permissions_v2).
  int _grantsRevision = 0;

  /// `accounts[0]` for the current page, from the webview's
  /// `onActiveAccountChanged` — feeds the key chip's emoji (site_active_key).
  String? _webActiveAccount;

  // Structural color for RSS feed view
  final Color myColor = ThemeProvider.tealPrimary;

  late AnimationController _animationController;
  late Animation<double> _profileAnimation;

  // New state variable for managing edit mode
  bool _isEditMode = false;

  // ── Channel sign-in on a channel tab ────────────────────────────────────
  // The key icon on the address bar mirrors the feeds tab's header: exists
  // iff the channel has signalled sign-in (a row), colour = the RULE's
  // answer, tap → Allow · Deny · Forget, then the list refetches under the
  // new posture. The ASK itself lives in PostsList (shared with the feeds
  // tab), which is why this browser needed no dialog of its own.
  ChannelSigninPref? _signinPref;
  bool _signinEffective = false;
  int _channelRefreshTick = 0;

  /// The channel tab's feed URL, when a channel tab is the current one.
  String? get _channelTabUrl {
    if (_currentTab != BrowserTab.channel || _currentCustomTabName == null) {
      return null;
    }
    for (final tab in _profileTabs) {
      if (tab.routerSubtype == RouterSubtype.channel &&
          (tab.metadata['name'] as String?) == _currentCustomTabName) {
        return tab.value;
      }
    }
    return null;
  }

  /// Re-query the row + the rule for the current channel tab. Runs when the
  /// tab's list settles (PostsList.onLoadingChanged) and after the menu.
  Future<void> _refreshSigninPref() async {
    final url = _channelTabUrl;
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
    if (!mounted || _channelTabUrl != url) return;
    setState(() {
      _signinPref = pref;
      _signinEffective = effective;
    });
  }

  Future<void> _showSigninMenu() async {
    final pref = _signinPref;
    final url = _channelTabUrl;
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
    setState(() => _channelRefreshTick++);
  }
  List<Record> _profileTabs = []; // New state variable for custom profile tabs
  String?
      _currentCustomTabName; // Stores the name of the currently selected custom profile tab
  List<Map<String, dynamic>> _chatTabs =
      []; // New state variable for fetched inbox IDs

  /// Bumped whenever tab data changes (_chatTabs / _profileTabs /
  /// _contactApps / _tabs) so an already-open tab-picker sheet recomputes
  /// its sections — the modal lives on its own route and never sees the
  /// page's setState otherwise.
  final ValueNotifier<int> _tabDataVersion = ValueNotifier<int>(0);
  String? _initialInboxId; // New state variable for the passed inboxId
  String?
      _selectedChatInboxId; // New state variable for the selected chat tab's inboxId
  bool _isOrgMember =
      false; // New state variable to track if user is a member of the group being viewed
  List<AppBookmark> _contactApps = []; // Apps registered by the contact
  AppBookmark? _currentApp; // Currently selected app tab
  bool _isCurrentAppBookmarked = false; // Track if current app is bookmarked
  bool _isCurrentRssFeedInList =
      false; // Track if current RSS feed is in any user list
  // Account-based follow (profile tab): does the viewer follow the whole
  // ACCOUNT whose profile is on screen — in ANY list? True iff the account
  // itself is a member somewhere; its channels appearing as individual list
  // items do NOT count.
  bool _isFollowingAccount = false;

  /// Is the account on the profile tab STARRED? A starred contact is one the
  /// user gets chain notifications about. Read with the follow state, written
  /// by [_toggleStarCurrentAccount].
  bool _isStarred = false;

  /// The star is offered on another account's profile, never on the user's
  /// own and never on the publicos org (always starred, no toggle).
  bool get _starShown =>
      _contact?.publicosAddress != null &&
      !_selfProfile &&
      !PublicOSContacts.isAlwaysStarred(_contact!.publicosAddress!);

  /// Past four buttons the row is too tight on a phone, so Edit moves into
  /// the "…" menu. That is exactly one case: another account's org that the
  /// user can edit (star + follow + edit + "…" + the tabs chevron).
  bool get _editInOverflow =>
      _starShown && _contact?.isOrgAccount == true && _isOrgMember;
  bool _togglingAccountFollow = false;
  // Opener for the hosted chat's conversation-settings sheet, bubbled up by
  // SimpleChatScreen once its topic resolves (null = no topic yet). Drives the
  // address-bar gear (chat tab only); see _onChatSettingsAvailable.
  VoidCallback? _chatSettingsOpener;

  // New animation controllers for tab container
  late AnimationController _tabAnimationController;

  // Marquee animation controller
  late AnimationController _marqueeAnimationController;
  Timer? _marqueeTimer;

  // Tab switch animation controller
  late AnimationController _tabSwitchAnimationController;

  // Constants for animation and layout, adapted from CustomAppBar and AppDimensions
  static const double kHorizontalPadding = 12.0;
  static const Duration kAnimationDuration = Duration(milliseconds: 300);

  // Directly defining dimensions for this monolithic file, inspired by dimensions.dart
  static const double _bannerHeightRatio = 1 / 5;
  static const double _collapsedHeaderHeightBase =
      56.0; // Base height for the collapsed address bar (without status bar)
  static const double _collapsedAvatarSize =
      32.0; // Adjusted for better visibility when collapsed
  static const double _expandedAvatarNaturalHeightRatio =
      0.068; // Base for expanded avatar size (e.g. ~64 at screenHeight=800)
  static const double _avatarExpandedScale =
      1.2; // Scaling factor for expanded avatar
  static const double _nameTagRadiusRatio =
      0.0096; // Derived from AppDimensions.borderRadius * 0.8

  double get _screenWidth => MediaQuery.of(context).size.width;
  double get _screenHeight => MediaQuery.of(context).size.height;
  // The device status-bar height, cached to the largest value seen. A system
  // sheet (e.g. the "open with" chooser) transiently HIDES the status bar,
  // dropping MediaQuery.viewPadding.top to 0 for a frame; reading it live made
  // the address-bar header collapse and the content below it jump up, then back
  // down when the bar returned. The real height never changes, so we ignore the
  // transient 0 and keep the header height stable.
  double _cachedStatusBarHeight = 0.0;
  double get _statusBarHeight {
    final live = MediaQuery.of(context).viewPadding.top;
    if (live > _cachedStatusBarHeight) _cachedStatusBarHeight = live;
    return _cachedStatusBarHeight;
  }
  double get _collapsedHeaderHeight =>
      _collapsedHeaderHeightBase + _statusBarHeight;

  double get _bannerHeight => _screenWidth * _bannerHeightRatio;
  // double get _expandedHeaderHeight => _bannerHeight + _statusBarHeight + 80;
  double get _expandedHeaderHeight => _bannerHeight + _statusBarHeight;

  List<_TabInfo> _tabs = [
    _TabInfo(
      tab: BrowserTab.profile,
      label: 'Profile',
    ),
    // _TabInfo(
    //   tab: BrowserTab.chat,
    //   label: 'Chat',
    // ),
    _TabInfo(
      tab: BrowserTab.settings,
      label: 'Settings',
    ),
  ];

  final GlobalKey _tabContainerKey = GlobalKey();

  /// Initial tab derived from the route. Every type lands directly on its
  /// target tab — tab→webview (an in-app payload refines to channel for feeds),
  /// app→app, chat→chat — so there's no profile flash; [_resolveLandingTab]
  /// then resolves the :key against the loaded contact (or confirms the in-app
  /// payload). settings/management/profile are direct.
  BrowserTab _initialTabForRoute() {
    switch (widget.routeType) {
      case 'settings':
        return BrowserTab.settings;
      case 'management':
        return BrowserTab.management;
      case 'tab':
        // Cold-link default shell; an in-app payload overrides _currentTab to
        // .channel for feeds in initState, and _resolveLandingTab flips a
        // cold link to .channel when the resolved record is a channel.
        return BrowserTab.webview;
      case 'app':
        return BrowserTab.app;
      case 'chat':
        // Land on the chat shell; _resolveLandingTab fills the inbox once the
        // on-chain label resolves (chat-by-label is external-only).
        return BrowserTab.chat;
      case 'profile':
        return BrowserTab.profile;
      default:
        // No :type segment — /inboxId and /conversationTopic land on chat;
        // a bare /publicosAddress/:address lands on profile.
        return widget.identifierType == ContactIdentifierType.xmtpInboxId ||
                widget.identifierType ==
                    ContactIdentifierType.xmtpConversationTopic
            ? BrowserTab.chat
            : BrowserTab.profile;
    }
  }

  /// Every mounted Browser, for [Browser.landInVisibleBrowser].
  static final Set<_BrowserState> _live = <_BrowserState>{};

  /// True when this Browser shows [address] and its route is the top one (a
  /// pageless page such as PostDetailPage pushed over it makes this false).
  bool _showsAddressOnTop(String address) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    final mine = _contact?.publicosAddress?.eip55With0x ??
        (widget.identifierType == ContactIdentifierType.publicosAddress
            ? widget.identifier
            : null);
    return mine != null && mine.toLowerCase() == address.toLowerCase();
  }

  /// The in-place half of [Browser.landInVisibleBrowser]: resolve the link's
  /// `:type/:key` the way [_resolveLandingTab] does, then switch through
  /// [_handleTabSelection] so Back returns to the tab this Browser opened on.
  bool _landInPlace(String? type, String? key) {
    void notFound(String message) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }

    switch (type) {
      case null:
      case 'profile':
        if (_currentTab != BrowserTab.profile) {
          _handleTabSelection(TabItem(
              browserTab: BrowserTab.profile,
              label: context.l10n.browserTabProfile));
        }
        return true;
      case 'tab':
        final record = _profileTabs
            .cast<Record?>()
            .firstWhere((t) => t?.key == key, orElse: () => null);
        if (record == null) {
          notFound(context.l10n.browserTabNotFound);
        } else {
          _handleTabSelection(TabItem(
              record: record,
              label: record.metadata['name'] as String? ?? 'Tab'));
        }
        return true;
      case 'app':
        final app = _contactApps.cast<AppBookmark?>().firstWhere(
            (a) => a?.appName == key && (a?.url?.isNotEmpty ?? false),
            orElse: () => null);
        if (app == null) {
          notFound(context.l10n.browserAppNotFound);
        } else {
          _handleTabSelection(
              TabItem(appBookmark: app, label: app.displayName));
        }
        return true;
      case 'chat':
        final addr = _contact?.publicosAddress;
        if (key == null || addr == null) return false;
        PublicOSXmtp.getAccountInboxIdByLabel(addr, key).then((bytes) {
          if (!mounted) return;
          if (bytes == null) {
            notFound(context.l10n.inboxIdsInboxNotFound);
            return;
          }
          final inboxId = bytes32ToString(bytes);
          final own = PublicOS.clientXmtpInboxId;
          // Your own inbox: nothing to open (the cold path lands on profile).
          if (own != null && inboxId.toLowerCase() == own.toLowerCase()) return;
          _handleTabSelection(TabItem(inboxId: inboxId, label: 'Chat'));
        });
        return true;
      default:
        return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _live.add(this);
    print('Browser: initState called');
    print('Browser: - widget.routeType: ${widget.routeType}');
    print('Browser: - widget.routeKey: ${widget.routeKey}');
    print('Browser: - widget.identifier: ${widget.identifier}');
    _currentTab = _initialTabForRoute();
    _displayedTab = _currentTab;
    _initialInboxId = widget.inboxId; // Initialize _initialInboxId

    // Check if we're being directed to chat with our currently loaded XMTP key's inbox ID
    final currentInboxId = PublicOS.clientXmtpInboxId;
    final isDirectedToSelfChat = _initialInboxId != null &&
        currentInboxId != null &&
        currentInboxId.isNotEmpty &&
        _initialInboxId!.toLowerCase() == currentInboxId.toLowerCase();

    if (widget.identifierType == ContactIdentifierType.xmtpInboxId &&
        _initialInboxId != null) {
      if (isDirectedToSelfChat) {
        print(
            'Browser: Detected self-chat attempt in initState, defaulting to profile');
        _currentTab = BrowserTab.profile;
        _selectedChatInboxId = null;
      } else {
        _currentTab = BrowserTab.chat;
        _selectedChatInboxId = _initialInboxId;
        _landingTabItem = TabItem(inboxId: _initialInboxId, label: 'Chat');
      }
    }

    // FULL deep-link landing: an in-app tap carries the destination via
    // go_router `extra`, so seed the content + landing tab synchronously here —
    // the target mounts on frame 1, no profile flash, no resolution wait. Runs
    // before the AnimationController below so the header seeds to match the
    // target: expanded for the expanded-header family (profile / channel),
    // collapsed otherwise. Cold/external links carry no payload and resolve
    // the :key in _resolveLandingTab instead.
    final landing = widget.landingPayload;
    if (landing is Record) {
      final isChannel = landing.routerSubtype == RouterSubtype.channel;
      _currentTab = isChannel ? BrowserTab.channel : BrowserTab.webview;
      _currentCustomTabName = landing.metadata['name'] as String?;
      if (!isChannel) _currentWebViewUrl = landing.value;
      _landingTabItem = TabItem(
          record: landing, label: landing.metadata['name'] as String? ?? 'Tab');
    } else if (landing is AppBookmark) {
      // `url` is a POINTER the app owner may simply never have set -- registering
      // an app and pointing it somewhere are two separate transactions. The `!`
      // here turned that ordinary state into a red screen of raw Flutter error
      // text. Callers refuse before navigating (apps_view/_launchApp), and this
      // stays non-asserting so a future entry point cannot resurrect the crash.
      _currentApp = landing;
      _currentWebViewUrl = landing.url ?? '';
      _currentTab = BrowserTab.app;
      _landingTabItem =
          TabItem(appBookmark: landing, label: landing.displayName);
      _recordAppOpen(landing);
    }
    _displayedTab = _currentTab;

    _loadContact();

    _animationController = AnimationController(
      duration: kAnimationDuration,
      vsync: this,
      value: _isExpandedHeaderTab ? 1.0 : 0.0,
    );

    // No global setState listener: only _buildAddressBar reads this value, so
    // it's wrapped in an AnimatedBuilder(_profileAnimation). Keeping the rebuild
    // scoped to the address bar lets the scroll-driven collapse stay smooth
    // without rebuilding the scrolling content every frame.
    _profileAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );

    if (_currentTab == BrowserTab.webview && widget.initialUrl != null) {
      _currentWebViewUrl = widget.initialUrl!;
    }

    // Initialize tab animation controller
    _tabAnimationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
      value: _currentTab == BrowserTab.profile ? 1.0 : 0.0,
    );

    // Initialize marquee animation controller
    _marqueeAnimationController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );

    // Initialize tab switch animation controller
    _tabSwitchAnimationController = AnimationController(
      duration: const Duration(milliseconds: 200), // Fast and snappy
      vsync: this,
      value: 1.0, // Start completed so initial tab is visible
    );

    _startMarqueeTimer();
  }

  /// Builds a TabItem that replays the original landing tab selection.
  TabItem _buildLandingTabItem() {
    switch (widget.routeType) {
      case 'app':
        // Try finding the app by name in loaded apps
        if (widget.routeKey != null) {
          final app = _contactApps.cast<AppBookmark?>().firstWhere(
              (a) => a?.appName == widget.routeKey,
              orElse: () => null);
          if (app != null)
            return TabItem(appBookmark: app, label: app.displayName);
        }
        return TabItem(browserTab: BrowserTab.profile, label: 'Profile');
      case 'tab':
        // Exact record-key match (web or channel tab)
        if (widget.routeKey != null) {
          final record = _profileTabs.cast<Record?>().firstWhere(
              (r) => r?.key == widget.routeKey,
              orElse: () => null);
          if (record != null)
            return TabItem(
                record: record,
                label: record.metadata['name'] as String? ?? 'Tab');
        }
        return TabItem(browserTab: BrowserTab.profile, label: 'Profile');
      case 'chat':
        // Label-resolved chat — _resolveLandingTab fills _selectedChatInboxId
        if (_selectedChatInboxId != null) {
          return TabItem(inboxId: _selectedChatInboxId, label: 'Chat');
        }
        return TabItem(browserTab: BrowserTab.profile, label: 'Profile');
      case 'settings':
        return TabItem(browserTab: BrowserTab.settings, label: 'Settings');
      case 'management':
        return TabItem(browserTab: BrowserTab.management, label: 'Management');
      default:
        // No :type — direct chat identifiers replay the chat tab; everything
        // else replays profile.
        if (_initialInboxId != null) {
          return TabItem(inboxId: _initialInboxId, label: 'Chat');
        }
        if (_currentTab == BrowserTab.chat) {
          return TabItem(browserTab: BrowserTab.chat, label: 'Chat');
        }
        return TabItem(browserTab: BrowserTab.profile, label: 'Profile');
    }
  }

  @override
  void didUpdateWidget(covariant Browser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.identifier != oldWidget.identifier ||
        widget.identifierType != oldWidget.identifierType) {
      _loadContact(); // This will also re-fetch chat tabs
    }
    if (widget.routeType != oldWidget.routeType ||
        widget.routeKey != oldWidget.routeKey ||
        widget.inboxId != oldWidget.inboxId) {
      _currentTab = _initialTabForRoute();
      _initialInboxId = widget.inboxId;
      if (_initialInboxId != null && _currentTab == BrowserTab.chat) {
        _selectedChatInboxId = _initialInboxId;
      } else {
        // If not a chat tab with a specific inboxId, or inboxId is null, clear _selectedChatInboxId
        _selectedChatInboxId = null;
      }

      // If tab changes, exit edit mode
      if (_isEditMode) {
        setState(() {
          _isEditMode = false;
        });
      }

      // Check for self-chat scenario after widget update
      _checkAndHandleSelfChatTab();
      _updateProfileAnimationState();
    }
  }

  Future<void> _loadContact() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _selfProfile = false;
      _isEditMode = false;
      _profileTabs = [];
      _chatTabs = [];
      _isOrgMember = false;
      _contactApps = [];
      _currentApp = null;
      _isSyncingFromChain = false;
      _chainSyncFailed = false;
    });

    try {
      Contact? contact;
      Contact? localContact;
      bool hasLocalData = false;

      // PHASE 1: Try to load from local database first
      if (widget.identifierType == ContactIdentifierType.publicosAddress) {
        localContact = await PublicOSContacts.searchContacts(widget.identifier);
        if (localContact != null && localContact.records.isNotEmpty) {
          hasLocalData = true;
          contact = localContact;
          // Check if self profile
          if (contact.publicosAddress != null &&
              AppStateNotifier.currentMyContact?.publicosAddress != null &&
              contact.publicosAddress!.eip55With0x ==
                  AppStateNotifier
                      .currentMyContact!.publicosAddress!.eip55With0x) {
            _selfProfile = true;
          }
        }
      } else if (widget.identifierType == ContactIdentifierType.xmtpInboxId) {
        localContact = await PublicOSContacts.searchContacts(widget.identifier);
        if (localContact != null) {
          hasLocalData = true;
          // Paint the local row immediately. If it lacks a publicosAddress
          // (XMTP-only) the shared paint tail kicks off resolveContact's
          // 3-stage ladder in the background via _resolveAndSyncInbox.
          contact = localContact;
        }
      } else if (widget.identifierType ==
          ContactIdentifierType.xmtpConversationTopic) {
        // Topic identifier may be either a group (stub keyed by topic) or a
        // DM that arrived via a notification tap (Core emits
        // `payload: "message:<topic>"` for every conversation regardless of
        // type). Try the group-stub lookup first; on miss, resolve the
        // conversation locally and fall back to the peer-inbox-id contact.
        localContact =
            await PublicOSContacts.findContactByTopic(widget.identifier);
        if (localContact != null) {
          hasLocalData = true;
          contact = localContact;
        } else {
          final conv =
              await PublicOSConversations.getConversation(widget.identifier);
          if (conv != null &&
              conv.type != ConversationType.group &&
              conv.peerInboxId != null) {
            contact =
                await PublicOSContacts.findContactByInboxId(conv.peerInboxId!);
            if (contact != null) {
              hasLocalData = true;
              _selectedChatInboxId = conv.peerInboxId;
            }
          }
        }
      }

      // If we have local data, show it immediately
      if (hasLocalData && contact != null) {
        if (mounted) {
          setState(() {
            _contact = contact;
            _isLoading = false; // Show content immediately
          });
          // Follow state for the profile tab's Follow button. The chain path
          // below (:836) does this too, but this branch returns early, and a
          // profile you follow is almost always stored locally, so it always
          // lands here (without it a followed profile shows "+").
          unawaited(_refreshAccountFollowState());
        }
        // Load tabs and apps from local data
        await _loadTabsAndApps(contact);

        // Initialize chat state for XMTP contacts
        _initializeChatState(contact);

        // Land on the deep-link target (or confirm the in-app payload).
        await _resolveLandingTab(contact);
        // Snapshot the landing tab once, while _currentTab still IS the landing
        // tab. Plain profile/settings/management/group-topic landings never set
        // _landingTabItem above, and the _buildLandingTabItem() fallback reads
        // the LIVE _currentTab at back-press time — by then the user may be on a
        // chat, so it would replay a generic chat shell instead of the profile.
        _landingTabItem ??= _buildLandingTabItem();

        // Background refresh. Choice depends on what we have locally:
        // - publicosAddress set: chain fetch + merge + tabs/apps refresh.
        // - XMTP-only with inbox id: run the resolution ladder; if it
        //   promotes the contact to a PublicOS account, hand off to
        //   _syncFromChain for the full refresh.
        // - group stub (topic only): nothing to refresh.
        if (contact.publicosAddress != null) {
          _syncFromChain(contact);
        } else if (contact.registeredInboxIDs != null &&
            contact.registeredInboxIDs!.isNotEmpty) {
          _resolveAndSyncInbox(contact);
        }
        return; // Exit early - sync will update UI when done
      }

      // PHASE 2: No local data - fetch from chain (blocking)
      // NOTE: Do NOT create DMs here — DM creation happens on first message send.
      if (widget.identifierType == ContactIdentifierType.publicosAddress) {
        contact = await PublicOSContacts.resolveByIdentifier(widget.identifier);
        if (contact != null &&
            contact.publicosAddress != null &&
            AppStateNotifier.currentMyContact?.publicosAddress != null &&
            contact.publicosAddress!.eip55With0x ==
                AppStateNotifier
                    .currentMyContact!.publicosAddress!.eip55With0x) {
          setState(() {
            _selfProfile = true;
          });
        }
      } else if (widget.identifierType == ContactIdentifierType.xmtpInboxId) {
        // Create a stub contact with session info (no DM), then resolve
        contact = await PublicOSContacts.findContactInfoOnly(widget.identifier);
        if (contact != null) {
          contact = await PublicOSContacts.resolveContact(contact,
              forceResolve: true);
        }
      } else if (widget.identifierType ==
          ContactIdentifierType.xmtpConversationTopic) {
        // No local stub yet (first tap before syncAll caught up). Pull the
        // conversation from DB/XMTP; if it's a group, materialize the stub
        // on the spot; if it's a DM masquerading via topic, resolve as DM.
        final conv =
            await PublicOSConversations.getConversation(widget.identifier);
        if (conv != null) {
          if (conv.type == ConversationType.group) {
            contact = await PublicOSContacts.ensureGroupStub(
              topic: conv.topic,
              groupName: conv.groupName ?? 'Unnamed Group',
              groupImageUrl: conv.groupImageUrl,
            );
          } else if (conv.peerInboxId != null) {
            contact =
                await PublicOSContacts.findContactByInboxId(conv.peerInboxId!);
            contact ??=
                await PublicOSContacts.findContactInfoOnly(conv.peerInboxId!);
            // Propagate the resolved peer inbox id so the chat tab can look
            // up the DM conversation. Without this the chat renders blank
            // because SimpleChatScreen falls through to its no-inboxId branch.
            if (contact != null) {
              _selectedChatInboxId = conv.peerInboxId;
            }
          }
        }
      }

      if (mounted) {
        final l10n = context.l10n;
        if (contact == null) {
          _error = l10n.browserContactNotFound;
        }
        setState(() {
          _contact = contact;
        });

        if (contact != null) {
          // Account-based follow state for the profile tab's Follow button.
          unawaited(_refreshAccountFollowState());
          // Fetch chat tabs (inbox IDs)
          if (contact!.publicosAddress != null) {
            try {
              final inboxData = await PublicOSXmtp.getAllAccountInboxIds(
                  contact.publicosAddress!);
              if (inboxData == null) {
                print(
                    'No inbox IDs found for contact: ${contact.publicosAddress?.eip55With0x}');
                if (mounted) {
                  setState(() {
                    _chatTabs = []; // Clear chat tabs if no inbox IDs found
                  });
                  _notifyTabDataChanged();
                }
              } else {
                final List<Map<String, dynamic>> chatTabs = [];

                for (int i = 0; i < inboxData.inboxIds.length; i++) {
                  final inboxIdBytes = inboxData.inboxIds[i];
                  final label = (i < inboxData.labels.length)
                      ? inboxData.labels[i]
                      : l10n.browserTabChat;
                  final inboxIdHex = inboxIdBytes
                      .map((b) => b.toRadixString(16).padLeft(2, '0'))
                      .join();

                  // The loaded inbox rides along flagged, not dropped: shown
                  // dimmed and inert by the switcher.
                  chatTabs.add({
                    'inboxId': inboxIdHex,
                    'label': label,
                    'isSelf': _isLoadedInbox(inboxIdHex),
                  });
                }
                if (mounted) {
                  setState(() {
                    _chatTabs = chatTabs;
                  });
                  _notifyTabDataChanged();
                }
              }
            } catch (e) {
              print('Error fetching inbox IDs: $e');
              if (mounted) {
                setState(() {
                  _chatTabs = [];
                });
                _notifyTabDataChanged();
              }
            }
          }
          // Synthetic chat tabs for XMTP-only contacts (no publicosAccount):
          // one per registered inbox, using the locally stored labels.
          else if (contact.registeredInboxIDs != null &&
              contact.registeredInboxIDs!.isNotEmpty) {
            print(
                'Browser: Creating synthetic chat tabs for XMTP-only contact');
            final localTabs =
                _localChatTabsFor(contact, l10n.browserTabChat);

            if (mounted) {
              setState(() {
                _chatTabs = localTabs;
                // If we're currently on the chat tab and _selectedChatInboxId
                // is not set, point it at the first local tab
                if (localTabs.isNotEmpty &&
                    _currentTab == BrowserTab.chat &&
                    _selectedChatInboxId == null) {
                  _selectedChatInboxId = localTabs.first['inboxId'] as String;
                  print(
                      'Browser: Set _selectedChatInboxId to: $_selectedChatInboxId');
                }
              });
              _notifyTabDataChanged();
            }
          }

          // Fetch profile tabs
          try {
            // CORRECTED LOGIC:
            final EthereumAddress? targetProfileAddress =
                contact.publicosAddress;
            if (targetProfileAddress != null) {
              final allRouterRecords = await PublicOSContacts.getRecordsByType(
                RecordType.router,
                targetAccountAddress:
                    targetProfileAddress, // Pass the address of the profile being viewed
              );
              final List<Record> fetchedTabs = allRouterRecords
                  .where((record) =>
                      (record.routerSubtype == RouterSubtype.tab ||
                          record.routerSubtype == RouterSubtype.channel) &&
                      !record.isExpired)
                  .toList();
              if (mounted) {
                setState(() {
                  _profileTabs = fetchedTabs;
                });
              }
            } else {
              // Handle case where the contact being viewed doesn't have a publicosAddress
              // (e.g., an XMTP-only contact without a full OSUX profile)
              if (mounted) {
                setState(() {
                  _profileTabs = []; // No tabs to show
                });
              }
            }
          } catch (e) {
            print(
                'Error fetching profile tabs: $e'); // It's good practice to keep logs for debugging
            if (mounted) {
              setState(() {
                _profileTabs =
                    []; // Clear tabs on error to prevent showing stale or incorrect data
              });
            }
          }

          // Check if user is a member of this group (for group accounts)
          try {
            if (contact.isOrgAccount &&
                contact.publicosAddress != null &&
                AppStateNotifier.currentMyContact?.publicosAddress != null) {
              // First, get all groups that the current user is a member of
              final userGroups = await PublicOSGovernance.getOrgsForAccount(
                  AppStateNotifier.currentMyContact!.publicosAddress!);

              // Check if the contact being viewed is one of the groups the user is a member of
              final isMember = userGroups.any((groupAddress) =>
                  groupAddress.eip55With0x.toLowerCase() ==
                  contact!.publicosAddress!.eip55With0x.toLowerCase());

              if (mounted) {
                setState(() {
                  _isOrgMember = isMember;
                });
              }
              print(
                  'Browser: Group membership check - User is ${isMember ? 'a member' : 'not a member'} of group ${contact.publicosDisplayName}');
              print(
                  'Browser: User groups: ${userGroups.map((g) => g.eip55With0x).toList()}');
              print(
                  'Browser: Target group: ${contact.publicosAddress!.eip55With0x}');
            }
          } catch (e) {
            print('Error checking group membership: $e');
            if (mounted) {
              setState(() {
                _isOrgMember = false;
              });
            }
          }

          // Fetch apps registered by this contact
          try {
            if (contact.publicosAddress != null) {
              print(
                  'Browser: Fetching apps for contact: ${contact.publicosAddress!.eip55With0x}');
              final apps = await PublicOSAppRegistry.getAllAccountApps(
                  contact.publicosAddress!);
              print(
                  'Browser: getAllAccountApps returned, apps is ${apps == null ? "null" : "not null"}, mounted=$mounted');

              if (apps == null) {
                print('Browser: getAllAccountApps returned null');
              } else {
                print('Browser: Found ${apps.length} total apps for contact');

                // Log each app
                for (var app in apps) {
                  print('  - App: ${app.appName} (${app.displayName})');
                  print('    URL: ${app.url ?? "NO URL"}');
                  print('    Owner: ${app.ownerAccountAddress.eip55With0x}');
                  print(
                      '    Pointers: ${app.pointers.map((p) => '${p.type}=${p.value}').join(', ')}');
                }

                // Filter to only apps with URL (can be launched in browser)
                final appsWithUrl = apps
                    .where((app) => app.url != null && app.url!.isNotEmpty)
                    .toList();
                print(
                    'Browser: ${appsWithUrl.length} apps have URLs and can be launched');

                if (mounted) {
                  setState(() {
                    _contactApps = appsWithUrl;
                  });
                }
              }
            } else {
              print(
                  'Browser: Contact has no publicosAddress, skipping app fetch');
            }
          } catch (e) {
            print('Browser: Error fetching contact apps: $e');
            print('Browser: Stack trace: ${StackTrace.current}');
            if (mounted) {
              setState(() {
                _contactApps = [];
              });
            }
          }

          // Sync messages for the primary inbox DM if the contact is not self.
          final primaryInboxId =
              contact.registeredInboxIDs?.firstOrNull?.inboxId;
          if (primaryInboxId != null &&
              contact.publicosAddress?.eip55With0x !=
                  AppStateNotifier
                      .currentMyContact?.publicosAddress?.eip55With0x) {
            final existingConv =
                await PublicOSConversations.getConversationByPeerInboxId(
                    primaryInboxId);
            if (existingConv != null) {
              PublicOSConversations.syncMessagesByTopic(existingConv.topic);
            }
          }

          // Check if we're initially directed to chat with our own inbox ID
          await _checkAndHandleSelfChatTab();

          // Land on the deep-link target (or confirm the in-app payload).
          await _resolveLandingTab(contact);
          // Snapshot the landing tab once, while _currentTab still IS the
          // landing tab (see the matching note on the local-data path).
          _landingTabItem ??= _buildLandingTabItem();

          // Save the contact locally so it persists for future visits
          PublicOSContacts.saveContact(contact);
        }
        setState(() {
          // Set isLoading to false after all loading is done
          _isLoading = false;
        });
        _updateTabsList();
        _updateProfileAnimationState();

        // Tail-of-flow: lazy enrichment for the cold-load path — one combined
        // pass, single setState (never blocks the UI).
        _enrichContactTail();
      }
    } catch (e) {
      if (mounted) {
        final l10n = context.l10n;
        setState(() {
          _error = localizedError(l10n, e);
          _isLoading = false;
        });
      }
    }
  }

  /// Returns [c] with `Contact.createdAt` read from chain. The stored value
  /// is what the profile shows while this runs; it is replaced only when the
  /// chain answers with a different date (fetched once and never
  /// refetched, a stale date could never correct itself). Pure: no
  /// setState, no save. A failed or empty read returns [c] unchanged.
  Future<Contact> _withCreatedAt(Contact c) async {
    final addr = c.publicosAddress;
    if (addr == null) return c;
    try {
      final created = await PublicOSAccounts.getAccountCreatedAt(
        addr,
        isOrg: c.isOrgAccount,
      );
      if (created == null) return c;
      final held = c.createdAt;
      if (held != null && held.isAtSameMomentAs(created)) return c;
      return c.copyWith(createdAt: created);
    } catch (_) {
      return c;
    }
  }

  /// Returns [c] with on-chain `Contact.isCitizen` refreshed — re-checked while
  /// not already `true` (citizenship is hard to lose, so a cached `true` is
  /// stable; `null`/`false` re-verify so newly-vouched citizens pick up). Org
  /// accounts are never citizens. Pure: no setState, no save. Failures return
  /// [c] unchanged.
  Future<Contact> _withCitizenship(Contact c) async {
    if (c.isCitizen == true || c.isOrgAccount) return c;
    final addr = c.publicosAddress;
    if (addr == null) return c;
    try {
      final isCitizen = await PublicOSAccounts.isCitizen(addr);
      return c.isCitizen == isCitizen ? c : c.copyWith(isCitizen: isCitizen);
    } catch (_) {
      return c; // couldn't determine — leave the cache untouched, retry later
    }
  }

  /// One-shot tail enrichment for the cold-load path (PHASE 2 of
  /// [_loadContact], which has no local contact to sync). Folds both lazy
  /// enrichments into a single `setState` so the profile rebuilds once, not
  /// per-value. The local-first path doesn't use this — [_syncFromChain]
  /// enriches inline before its own single setState. Never call from list
  /// flows (n+1 trap).
  Future<void> _enrichContactTail() async {
    final c = _contact;
    if (c == null || c.publicosAddress == null) return;
    var enriched = await _withCreatedAt(c);
    enriched = await _withCitizenship(enriched);
    if (identical(enriched, c)) return; // nothing changed
    if (!mounted) return;
    if (_contact?.publicosAddress?.eip55With0x !=
        c.publicosAddress!.eip55With0x) {
      return; // navigated to a different contact while enriching
    }
    setState(() => _contact = enriched);
    PublicOSContacts.saveContact(enriched);
  }

  /// Loads tabs and apps from contact data (used for both local and chain data)
  Future<void> _loadTabsAndApps(Contact contact) async {
    // Load profile tabs from records
    if (contact.publicosAddress != null) {
      try {
        final allRouterRecords =
            contact.records.where((r) => r.type == RecordType.router).toList();
        final List<Record> fetchedTabs = allRouterRecords
            .where((record) =>
                (record.routerSubtype == RouterSubtype.tab ||
                    record.routerSubtype == RouterSubtype.channel) &&
                !record.isExpired)
            .toList();
        if (mounted) {
          setState(() {
            _profileTabs = fetchedTabs;
          });
        }
      } catch (e) {
        print('Error loading profile tabs: $e');
      }
    }

    // Load apps registered by this contact
    if (contact.publicosAddress != null) {
      try {
        print(
            'Browser: _loadTabsAndApps - Fetching apps for: ${contact.publicosAddress!.eip55With0x}');
        final apps = await PublicOSAppRegistry.getAllAccountApps(
            contact.publicosAddress!);
        if (apps != null && mounted) {
          final appsWithUrl = apps
              .where((app) => app.url != null && app.url!.isNotEmpty)
              .toList();
          print(
              'Browser: _loadTabsAndApps - Found ${appsWithUrl.length} apps with URLs');
          setState(() {
            _contactApps = appsWithUrl;
          });
        }
      } catch (e) {
        print('Browser: Error loading apps in _loadTabsAndApps: $e');
      }
    }

    _updateTabsList();
    _updateProfileAnimationState();
  }

  /// Initializes chat state for XMTP contacts (synthetic chat tabs and _selectedChatInboxId)
  /// This handles contacts that have registered inbox IDs but may not have
  /// a full publicosAccount resolved on chain yet.
  void _initializeChatState(Contact contact) {
    // Only create synthetic chat tab if the contact has at least one registered inbox id
    if (contact.registeredInboxIDs == null ||
        contact.registeredInboxIDs!.isEmpty) {
      return;
    }

    print('Browser: _initializeChatState for contact: ${contact.displayName}');
    // One tab per registered inbox, carrying the locally stored label
    // (InboxEntry.label) so first paint matches what the chain sync will
    // later confirm — 'Chat' is only the empty-label fallback. Self inboxes
    // are skipped (can't message ourselves), same rule as the chain path.
    final localTabs = _localChatTabsFor(contact, context.l10n.browserTabChat);

    if (localTabs.isEmpty) {
      print(
          'Browser: Skipping synthetic chat tabs (self-chat or no valid identifier)');
      return;
    }

    if (mounted) {
      setState(() {
        // Only set _chatTabs if it's empty (don't override if already populated from chain)
        if (_chatTabs.isEmpty) {
          _chatTabs = localTabs;
        }
        // If we're currently on the chat tab and _selectedChatInboxId is not set,
        // set it to match the first local tab
        if (_currentTab == BrowserTab.chat && _selectedChatInboxId == null) {
          _selectedChatInboxId = localTabs.first['inboxId'] as String;
          print(
              'Browser: Set _selectedChatInboxId to: $_selectedChatInboxId');
        }
      });
      _notifyTabDataChanged();
    }
  }

  /// Maps a contact's locally stored [InboxEntry] list to chat-tab entries,
  /// falling back to [fallbackLabel] when the stored label is empty.
  ///
  /// The inbox this device currently has loaded is NOT skipped:
  /// it rides along flagged `isSelf`, so the switcher can show it
  /// dimmed and inert instead of dropping it and leaving the user hunting for
  /// a tab that silently vanished.
  List<Map<String, dynamic>> _localChatTabsFor(
      Contact contact, String fallbackLabel) {
    final tabs = <Map<String, dynamic>>[];
    for (final entry in contact.registeredInboxIDs ?? <InboxEntry>[]) {
      final label = entry.label.trim();
      tabs.add({
        'inboxId': entry.inboxId,
        'label': label.isNotEmpty ? label : fallbackLabel,
        'isSelf': _isLoadedInbox(entry.inboxId),
      });
    }
    return tabs;
  }

  /// True when [inboxId] is the inbox this device has loaded into XMTP right
  /// now (`PublicOS.clientXmtpInboxId`, set from the client's own inbox when a
  /// key is loaded and cleared on key change). Deliberately NOT a check of
  /// whose profile is open: an org admin holding the org's Admin key matches
  /// it on the ORG's profile.
  bool _isLoadedInbox(String inboxId) {
    final current = PublicOS.clientXmtpInboxId;
    return current != null &&
        current.isNotEmpty &&
        inboxId.toLowerCase() == current.toLowerCase();
  }

  /// Unified landing resolver — replaces the old per-type trio
  /// (_handleAppRouting / _handleTabRouting / _handleChatRouting). Resolves the
  /// route :key against the loaded contact, sets the target tab + content,
  /// captures _landingTabItem (back-nav INV-1), and runs the collapse/tabs tail
  /// exactly once. Raw setState only — never _handleTabSelection (INV-3), which
  /// would flag the browser as already-navigated-away on arrival.
  ///
  /// When an in-app payload already seeded the landing in initState (FULL path)
  /// this is a confirm; a key-miss against a stale local cache is then a no-op
  /// (the payload landing stands). Only a payload-less cold link that misses
  /// falls back to profile + a "not found" snackbar.
  Future<void> _resolveLandingTab(Contact contact) async {
    final type = widget.routeType;
    if (type != 'tab' && type != 'app' && type != 'chat') return;
    if (widget.routeKey == null) return;

    final hasPayload = widget.landingPayload != null;
    bool resolved = false;

    if (type == 'tab') {
      final matchingTab = _profileTabs.cast<Record?>().firstWhere(
            (tab) => tab?.key == widget.routeKey,
            orElse: () => null,
          );
      if (matchingTab != null) {
        final name = matchingTab.metadata['name'] as String?;
        final isChannel = matchingTab.routerSubtype == RouterSubtype.channel;
        _currentTab = isChannel ? BrowserTab.channel : BrowserTab.webview;
        _currentCustomTabName = name;
        if (!isChannel) _currentWebViewUrl = matchingTab.value;
        _landingTabItem = TabItem(record: matchingTab, label: name ?? 'Tab');
        resolved = true;
      }
    } else if (type == 'app') {
      final targetApp = _contactApps.firstWhere(
        (app) => app.appName == widget.routeKey,
        orElse: () => AppBookmark(
          appName: '',
          displayName: '',
          ownerAccountAddress: contact.publicosAddress!,
        ),
      );
      if (targetApp.appName.isNotEmpty &&
          targetApp.url != null &&
          targetApp.url!.isNotEmpty) {
        _currentApp = targetApp;
        _currentWebViewUrl = targetApp.url!;
        _currentTab = BrowserTab.app;
        _landingTabItem =
            TabItem(appBookmark: targetApp, label: targetApp.displayName);
        _checkCurrentAppBookmarkStatus();
        _recordAppOpen(targetApp);
        resolved = true;
      }
    } else {
      // chat-by-label — resolve the label to the CURRENT inbox via the on-chain
      // registry (survives the owner rotating keys). External-only; lands
      // on the chat shell, which surfaces its own resolution/empty state.
      final addr = contact.publicosAddress;
      if (addr != null) {
        final inboxIdBytes =
            await PublicOSXmtp.getAccountInboxIdByLabel(addr, widget.routeKey!);
        if (inboxIdBytes != null) {
          final inboxId = bytes32ToString(inboxIdBytes);
          final currentInboxId = PublicOS.clientXmtpInboxId;
          final isSelf = currentInboxId != null &&
              currentInboxId.isNotEmpty &&
              inboxId.toLowerCase() == currentInboxId.toLowerCase();
          if (isSelf) {
            // Can't chat ourselves — fall back to the profile (quiet, as before).
            _currentTab = BrowserTab.profile;
          } else {
            _currentTab = BrowserTab.chat;
            _selectedChatInboxId = inboxId;
            _landingTabItem = TabItem(inboxId: inboxId, label: 'Chat');
            resolved = true;
          }
        }
      }
    }

    // A payload-less cold link to a deleted record / removed app resolves to
    // nothing → fall back to profile + a quick snackbar so the land-direct shell
    // can't strand the user. With a payload present the seeded landing stands;
    // chat keeps its shell (the chat screen surfaces its own empty state).
    if (!resolved && !hasPayload && type != 'chat') {
      _currentTab = BrowserTab.profile;
      _currentApp = null;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(type == 'app'
                ? context.l10n.browserAppNotFound
                : context.l10n.browserTabNotFound),
          ),
        );
      }
    }

    // Sync the lagged mirror — landing is a resolve, not a user switch, so the
    // tabs agree at rest (otherwise the landed tab's right-side icons, gated on
    // _currentTab == _displayedTab, wouldn't render on the cold webview→channel
    // resolve).
    if (mounted) setState(() => _displayedTab = _currentTab);
    _updateTabsList();
    _updateProfileAnimationState();
  }

  /// Syncs contact data from chain in the background
  Future<void> _syncFromChain(Contact localContact) async {
    final l10n = context.l10n;
    if (mounted) setState(() => _isSyncingFromChain = true);

    if (localContact.publicosAddress == null) {
      // No chain address - nothing to sync
      if (mounted) {
        setState(() {
          _isSyncingFromChain = false;
        });
      }
      return;
    }

    try {
      // Fetch fresh data from chain
      // requireRecords: the merge below overwrites `records` wholesale onto a
      // KNOWN-GOOD local contact and saves it. Without this, a records read
      // that fails silently returns [], we persist that over real data and
      // stamp it fresh — the one site in the app that actively destroys a good
      // profile. On throw we land in the catch below, which already surfaces
      // _chainSyncFailed and leaves the local copy on screen.
      final freshContact = await PublicOSContacts.fetchContact(
        localContact.publicosAddress!,
        requireRecords: true,
      );

      // Merge with local data (keep conversation topic, group status, etc.)
      var mergedContact = localContact.copyWith(
        // An account's shown name is the chain's (fetchContact re-derives it
        // on every read); without this a renamed account kept its old name
        // on its own profile and the save below re-staled the DB row.
        displayName: freshContact.displayName,
        records: freshContact.records,
        publicosDisplayName: freshContact.publicosDisplayName ??
            localContact.publicosDisplayName,
        registeredInboxIDs: (freshContact.registeredInboxIDs != null &&
                freshContact.registeredInboxIDs!.isNotEmpty)
            ? freshContact.registeredInboxIDs
            : localContact.registeredInboxIDs,
        isOrgAccount: freshContact.isOrgAccount || localContact.isOrgAccount,
        createdBy: freshContact.createdBy ?? localContact.createdBy,
        // fetchContact gets orgMemberCount and the merge must keep it;
        // founderAddress likewise.
        orgMemberCount:
            freshContact.orgMemberCount ?? localContact.orgMemberCount,
        founderAddress:
            freshContact.founderAddress ?? localContact.founderAddress,
        // Carry the verify-at-fetch enrichments fetchContact now resolves
        // (NFT verdict + org public/private flag). Without these the merge keeps
        // localContact's STALE verdict next to the fresh records → the now-
        // presentational icon shows the wrong/fallback avatar (it no longer
        // self-heals on a pointer mismatch), and saveContact below would
        // re-stale the shared DB cache. isCitizen is refreshed by
        // _withCitizenship just below (its false→true re-check semantics).
        verifiedNftAvatar: freshContact.verifiedNftAvatar,
        isPublicOrg: freshContact.isPublicOrg,
      );

      // Fold the lazy enrichments in here so this whole sync is a single
      // _contact mutation (one setState below) — no separate tail setState
      // calls, each of which re-triggered ProfilePage. createdAt keeps the
      // stored date unless the chain returns a different one; isCitizen
      // re-checks while not true.
      mergedContact = await _withCreatedAt(mergedContact);
      mergedContact = await _withCitizenship(mergedContact);

      // Save to database
      await PublicOSContacts.saveContact(mergedContact);

      // Fetch chat tabs from chain
      List<Map<String, dynamic>> chatTabs = [];
      try {
        final inboxData = await PublicOSXmtp.getAllAccountInboxIds(
            mergedContact.publicosAddress!);
        if (inboxData != null) {
          for (int i = 0; i < inboxData.inboxIds.length; i++) {
            final inboxIdBytes = inboxData.inboxIds[i];
            final label = (i < inboxData.labels.length)
                ? inboxData.labels[i]
                : l10n.browserTabChat;
            final inboxIdHex = inboxIdBytes
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join();

            // Flagged, not skipped - see _localChatTabsFor.
            chatTabs.add({
              'inboxId': inboxIdHex,
              'label': label,
              'isSelf': _isLoadedInbox(inboxIdHex),
            });
          }
        }
      } catch (e) {
        print('Error fetching inbox IDs during sync: $e');
      }

      // Fetch apps from chain
      List<AppBookmark> apps = [];
      try {
        final fetchedApps = await PublicOSAppRegistry.getAllAccountApps(
            mergedContact.publicosAddress!);
        if (fetchedApps != null) {
          apps = fetchedApps
              .where((app) => app.url != null && app.url!.isNotEmpty)
              .toList();
        }
      } catch (e) {
        print('Error fetching apps during sync: $e');
      }

      // Check group membership
      bool isOrgMember = false;
      if (mergedContact.isOrgAccount &&
          AppStateNotifier.currentMyContact?.publicosAddress != null) {
        try {
          final userGroups = await PublicOSGovernance.getOrgsForAccount(
              AppStateNotifier.currentMyContact!.publicosAddress!);
          isOrgMember = userGroups.any((groupAddress) =>
              groupAddress.eip55With0x.toLowerCase() ==
              mergedContact.publicosAddress!.eip55With0x.toLowerCase());
        } catch (e) {
          print('Error checking group membership: $e');
        }
      }

      // Update UI with fresh data
      if (mounted) {
        // Get fresh profile tabs
        final allRouterRecords = mergedContact.records
            .where((r) => r.type == RecordType.router)
            .toList();
        final freshTabs = allRouterRecords
            .where((record) =>
                (record.routerSubtype == RouterSubtype.tab ||
                    record.routerSubtype == RouterSubtype.channel) &&
                !record.isExpired)
            .toList();

        setState(() {
          _contact = mergedContact;
          _profileTabs = freshTabs;
          _chatTabs = chatTabs;
          _contactApps = apps;
          _isOrgMember = isOrgMember;
          _isSyncingFromChain = false;
          _chainSyncFailed = false;
        });
        _updateTabsList();
      }
    } catch (e) {
      print('Error syncing from chain: $e');
      if (mounted) {
        setState(() {
          _isSyncingFromChain = false;
          _chainSyncFailed = true;
        });
      }
    }
  }

  /// Background equivalent of the old blocking `resolveContact(force:true)`
  /// for XMTP-only locals (no publicosAddress yet). Runs the 3-stage
  /// resolution ladder; if it promotes the contact to a full PublicOS
  /// account, swaps the displayed contact, reloads its tabs/apps from the
  /// promoted records, and hands off to [_syncFromChain] for the full
  /// chain refresh.
  Future<void> _resolveAndSyncInbox(Contact localContact) async {
    if (mounted) setState(() => _isSyncingFromChain = true);

    // Capture the identifier this resolve was started for, so a late
    // completion after the user navigated away does not stomp the new
    // contact (mirrors the guard in _enrichContactTail).
    final originInboxId =
        localContact.registeredInboxIDs?.firstOrNull?.inboxId;

    try {
      final resolved = await PublicOSContacts.resolveContact(
        localContact,
        forceResolve: true,
      );

      if (!mounted) return;
      final currentInboxId =
          _contact?.registeredInboxIDs?.firstOrNull?.inboxId;
      if (currentInboxId != originInboxId) return;

      if (resolved.publicosAddress != null) {
        // Promoted to a full PublicOS contact. Show it, refresh tabs/apps
        // from its records, then run the regular chain sync to enrich
        // (citizenship, createdAt, fresh chat tabs from chain, etc.).
        setState(() => _contact = resolved);
        await _loadTabsAndApps(resolved);
        _initializeChatState(resolved);
        _syncFromChain(resolved);
      } else {
        // Still XMTP-only (no PublicOS account behind this inbox). May
        // have picked up ENS/Farcaster data from stages 2-3.
        setState(() {
          _contact = resolved;
          _isSyncingFromChain = false;
        });
      }
    } catch (e) {
      print('Browser: _resolveAndSyncInbox error: $e');
      if (mounted) {
        setState(() {
          _isSyncingFromChain = false;
          _chainSyncFailed = true;
        });
      }
    }
  }

  /// Retry sync from chain after a failure. Dispatches the same way the
  /// initial paint tail does so XMTP-only contacts retry the resolve
  /// ladder, not a no-op _syncFromChain.
  void _retrySyncFromChain() {
    if (_contact == null || _isSyncingFromChain) return;
    setState(() => _chainSyncFailed = false);
    if (_contact!.publicosAddress != null) {
      _syncFromChain(_contact!);
    } else if (_contact!.registeredInboxIDs != null &&
        _contact!.registeredInboxIDs!.isNotEmpty) {
      _resolveAndSyncInbox(_contact!);
    }
  }

  /// True when the browsed contact is the signed-in account. Its settings live
  /// in the Account system app, not here — see [_updateTabsList].
  bool get _isViewingSelf {
    final address = _contact?.publicosAddress;
    return address != null &&
        address == AppStateNotifier.currentMyContact?.publicosAddress;
  }

  void _updateTabsList() {
    setState(() {
      final isOrg = _contact?.isOrgAccount == true;

      // Order: Profile, Chat, Management, Settings. Self-account settings live
      // in the Account system app; every other
      // contact type — orgs, other accounts, group chats, XMTP-only — keeps its
      // Settings tab.
      _tabs = [
        _TabInfo(tab: BrowserTab.profile, label: 'Profile'),
        if (_chatTabs.isNotEmpty) _TabInfo(tab: BrowserTab.chat, label: 'Chat'),
        if (isOrg) _TabInfo(tab: BrowserTab.management, label: 'Management'),
        if (!_isViewingSelf)
          _TabInfo(tab: BrowserTab.settings, label: 'Settings'),
      ];

      // A tab that no longer exists can't stay selected. Both cases arrive via
      // deep link — /<addr>/management on a non-org, /<my-addr>/settings on me.
      if (_currentTab == BrowserTab.management && !isOrg) {
        _currentTab = BrowserTab.profile;
      }
      if (_currentTab == BrowserTab.settings && _isViewingSelf) {
        _currentTab = BrowserTab.profile;
      }
    });
    _notifyTabDataChanged();
  }

  /// Pokes an open tab-picker sheet (see [_showTabPickerSheet]) to recompute
  /// its sections. Call after any setState that mutates tab data.
  void _notifyTabDataChanged() => _tabDataVersion.value++;

  void _selectTab(BrowserTab newTab) {
    // if (newTab == _currentTab && newTab != BrowserTab.webview) return; // Allow re-selecting webview if URL changes (handled by custom tab logic)
    // The above line was part of a previous complex change, simplifying for now:
    if (newTab == _currentTab &&
        (_currentCustomTabName == null && newTab == BrowserTab.webview)) return;

    setState(() {
      _currentTab = newTab;
      _error = null;
      _currentCustomTabName =
          null; // Clear custom tab name when a static tab is selected
      if (newTab != BrowserTab.chat) {
        // If not selecting a chat tab, clear selected inbox id
        _selectedChatInboxId = null;
      }
      if (newTab != BrowserTab.app) {
        // If not selecting app tab, clear app state
        _currentApp = null;
        _isCurrentAppBookmarked = false;
      }

      // If navigating away from profile tab or to a different profile, exit edit mode.
      if (newTab != BrowserTab.profile && _isEditMode) {
        _isEditMode = false;
      }
    });

    // If the static "Web View" tab is selected, set the URL
    // Custom tabs will have already set their specific URLs
    if (newTab == BrowserTab.webview) {
      // Use widget.initialUrl if available and current tab is webview, otherwise a placeholder.
      // This ensures that if user explicitly clicks "Web View", it has a defined target.
      final String urlToLoad =
          (widget.initialUrl != null && widget.initialUrl!.isNotEmpty)
              ? widget.initialUrl!
              : "https://google.com"; // Default/fallback URL for generic Web View
      _currentWebViewUrl = urlToLoad;
    }

    _updateProfileAnimationState();

    // Restart marquee timer when switching tabs (_currentTab is already
    // newTab here, so the expanded-family getter answers for the new tab).
    if (!_isExpandedHeaderTab) {
      _startMarqueeTimer();
    }
  }

  // Schedules _displayedTab to catch up to _currentTab after the path
  // AnimatedSwitcher's 200ms exit. Idempotent across rebuilds: only
  // arms a new Timer when the pending target actually changes.
  void _scheduleDisplayedTabCatchUp() {
    if (_displayedTab == _currentTab) {
      _pendingDisplayedTab = null;
      return;
    }
    final pending = _currentTab;
    if (_pendingDisplayedTab == pending) return;
    _pendingDisplayedTab = pending;
    _displayedTabTimer?.cancel();
    _displayedTabTimer = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      if (_currentTab != pending) return; // tab changed again mid-wait
      setState(() {
        _displayedTab = pending;
        _pendingDisplayedTab = null;
      });
    });
  }

  /// Tabs in the "expanded header" family: they land with the banner + big
  /// avatar fully expanded and the content's scroll drives the collapse.
  /// Channel (RSS) tabs join profile + management here — same
  /// animation, driven by PostsList's scroll via its topInset contract.
  bool get _isExpandedHeaderTab =>
      _currentTab == BrowserTab.profile ||
      _currentTab == BrowserTab.management ||
      _currentTab == BrowserTab.channel;

  void _updateProfileAnimationState() {
    final isExpandedView = _isExpandedHeaderTab;
    if (isExpandedView) {
      _animationController.forward();
      _tabAnimationController
          .forward(); // Animate tab to circular when in profile
    } else {
      _animationController.reverse();
      _tabAnimationController
          .reverse(); // Animate tab to full width when not in profile
    }
  }

  /// The expanded address-bar visual height (banner + avatar/name overflow) —
  /// mirrors the `adjustedHeaderHeight` math in [_buildAddressBar] at full
  /// expansion (progress 1). Used as the content's top inset and as the scroll
  /// travel over which the header collapses, so the content rises in lockstep
  /// with the shrinking header.
  double get _expandedVisualHeight {
    const double p = 1.0;
    final double base = _calculateAddressBarHeight(p);
    final double avatarBottom = _calculateAvatarY(p) + _calculateAvatarSize(p);
    return base > avatarBottom ? base : avatarBottom + 8;
  }

  /// Profile/management collapse is driven by the content scroll: at the top the
  /// header is fully expanded (progress 1); scrolling collapses it to the strip
  /// (progress 0) over `_expandedVisualHeight - _collapsedHeaderHeight` of
  /// travel (1:1 with the content rising), then the content scrolls under the
  /// opaque strip. Other tabs don't drive it (their header stays collapsed).
  ///
  /// Position only, never scroll activity: a [ContentMetricsListener] feeds
  /// this from update and metrics notifications (the metrics one covers a
  /// page that shrinks under a scrolled offset, e.g. org
  /// Management, scroll the open Voting list, then close it; Flutter corrects
  /// `pixels` with no scroll update). It also keeps nested scrollers out
  /// (management's capped Records box bubbles at depth >= 1; letting it in
  /// snapped the avatar to the inner list's top). Start/end notifications
  /// can fire inside layout, and writing the animation value there throws
  /// "Build scheduled during frame".
  void _syncHeaderToScroll(ScrollMetrics metrics) {
    if (!_isExpandedHeaderTab) return;
    final double dist =
        (_expandedVisualHeight - _collapsedHeaderHeight).clamp(1.0, double.infinity);
    final double px = metrics.pixels < 0 ? 0 : metrics.pixels;
    final double progress = (1 - (px / dist)).clamp(0.0, 1.0);
    if ((_animationController.value - progress).abs() > 0.001) {
      _animationController.value = progress;
    }
  }

  void _startMarqueeTimer() {
    _marqueeTimer?.cancel();
    _marqueeTimer = Timer.periodic(const Duration(seconds: 12), (timer) {
      if (!_isExpandedHeaderTab && mounted) {
        _marqueeAnimationController.forward().then((_) {
          _marqueeAnimationController.reverse();
        });
      }
    });
  }

  void _stopMarqueeTimer() {
    _marqueeTimer?.cancel();
    _marqueeTimer = null;
  }

  Widget _buildMarqueeText(String text, ThemeData theme, double marqueeValue,
      double availableWidth, double currentProgress) {
    final textStyle = theme.textTheme.bodyMedium!
        .copyWith(fontWeight: FontWeight.w600, fontSize: 14);

    final textPainter = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    final textWidth = textPainter.size.width;

    // Calculate the offset for marquee effect
    final double maxOffset = textWidth - availableWidth;
    final double currentOffset = maxOffset * marqueeValue;

    return Stack(
      children: [
        Transform.translate(
          offset: Offset(-currentOffset, 0),
          child: Text(
            text,
            style: textStyle,
            maxLines: 1,
            overflow: TextOverflow.visible,
          ),
        ),
        // Fade effect at the end (where text meets the icon)
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 30, // Wider fade area
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Colors.transparent,
                  theme.colorScheme.surface
                      .withValues(alpha: 0.6 * currentProgress),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  double _calculateAddressBarHeight(double t) {
    return _collapsedHeaderHeight +
        ((_expandedHeaderHeight - _collapsedHeaderHeight) * t);
  }

  double _calculateAvatarSize(double t) {
    final double expandedTargetBaseSize =
        _screenHeight * _expandedAvatarNaturalHeightRatio;
    final double expandedFinalSize =
        expandedTargetBaseSize * _avatarExpandedScale;
    return _collapsedAvatarSize +
        (expandedFinalSize - _collapsedAvatarSize) * t;
  }

  double _calculateAvatarX(double t) {
    // Start at left edge padding (no back button anymore)
    final double startX = kHorizontalPadding;
    final double endX = kHorizontalPadding;
    return startX + (endX - startX) * t;
  }

  double _calculateAvatarY(double t) {
    final double currentAvatarSize = _calculateAvatarSize(t);
    // When collapsed, center avatar in the base header height (below status bar)
    // Center = statusBarHeight + (collapsedHeaderHeightBase / 2)
    // Avatar top = Center - (avatarSize / 2)
    final double startY = _statusBarHeight +
        (_collapsedHeaderHeightBase - (currentAvatarSize + 10)) / 2;
    // When expanded, position avatar at bottom of banner (banner + statusBar - half avatar size)
    final double endY =
        _statusBarHeight + _bannerHeight - currentAvatarSize / 2.8;
    return startY + (endY - startY) * t;
  }

  Widget _buildEditButton(BuildContext context, VoidCallback onTap) {
    // Show edit button for own profile OR if user is a member of a group account
    bool canEdit =
        (_selfProfile) || (_contact?.isOrgAccount == true && _isOrgMember);
    if (!canEdit || _currentTab != BrowserTab.profile)
      return const SizedBox.shrink();

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.edit_rounded,
          size: 18,
          color: Colors.white,
        ),
      ),
    );
  }

  void _showEditImageSheet(
      BuildContext context, String type, String? currentUrl) {
    // Allow editing for own profile OR if user is a member of a group account
    bool canEdit =
        (_selfProfile) || (_contact?.isOrgAccount == true && _isOrgMember);
    if (!canEdit) return;

    // Hand the sheet the LIVE NFT state (ref + already-resolved art +
    // ownership verdict) so its landing previews what the profile actually
    // renders — NFT-wins — with no re-resolve flash.
    final nft = type == 'avatar'
        ? _contact?.nftAvatar
        : type == 'banner'
            ? _contact?.nftBanner
            : null;
    var nftVerdict = type == 'avatar'
        ? _contact?.verifiedNftAvatarData
        : type == 'banner'
            ? _contact?.verifiedNftBannerData
            : null;
    // A verdict cached for a different pointer is stale — don't seed the
    // sheet's preview with the wrong art; it'll resolve fresh instead.
    if (nft == null || (nftVerdict != null && !nftVerdict.matches(nft))) {
      nftVerdict = null;
    }

    showEditProfileImageSheet(
      context,
      type: type,
      currentImageUrl: currentUrl,
      currentNft: nft,
      currentNftImage: nftVerdict?.imageUrl,
      currentNftOwned: nftVerdict?.verifiedOwnership,
      onSave: (record) async {
        bool saved = false;

        if (_selfProfile) {
          // Own profile - use regular setRecord
          saved = await PublicOSContacts.setRecord(record);
        } else if (_contact?.isOrgAccount == true &&
            _isOrgMember &&
            _contact?.publicosAddress != null) {
          // Org record — route through governance. startVoteSetRecord
          // resolves once the startVote tx is confirmed mined: threshold-1
          // orgs execute the change in that tx, threshold-N open a vote.
          saved = await PublicOSGovernance.startVoteSetRecord(
            _contact!.publicosAddress!,
            key: record.key,
            value: jsonEncode(record.toChainValue()),
            expiration: record.chainExpiration,
            recordType: BigInt.from(record.type.index),
            customType: record.subtype ?? '',
          );
        }

        if (saved) {
          final voteOpen = await _isOrgVoteOpen();
          await _loadContact(); // Full reload so the live vote shows
          if (mounted) {
            final l10n = context.l10n;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(voteOpen
                    ? l10n.browserVoteStartedMembersApprove
                    : l10n.browserProfileImageUpdated),
              ),
            );
          }
        } else if (mounted && _contact?.isOrgAccount == true && !_selfProfile) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.browserCouldNotStartVote)),
          );
        }
      },
    );
  }

  /// Set an NFT (from the NFT info dialog) as the current user's avatar —
  /// writes the `profile.avatar.nft` record directly behind the canonical
  /// blocking "Saving to chain..." overlay, then refreshes the global self
  /// contact so the new avatar propagates app-wide. Always a self-write (you're
  /// setting YOUR avatar), so no org-governance path. Returns success so the
  /// dialog can close itself.
  Future<bool> _useNftAsAvatar(NftAvatarRef ref) async {
    final l10n = context.l10n;
    final overlay =
        FullscreenOverlay.showTransaction(context, l10n.browserSavingToChain);
    try {
      final record = Record.asSettings(
        key: 'profile.avatar.nft',
        value: ref.encode(),
        isSystem: true,
      );
      final ok = await PublicOSContacts.setRecord(record);
      if (ok) {
        overlay.updateMessage(l10n.browserRefreshingProfile);
        await AppStateNotifier.loadMyContact();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok
                ? l10n.browserAvatarUpdated
                : l10n.browserCouldNotSetAvatar),
          ),
        );
      }
      return ok;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.browserCouldNotSetAvatar)),
        );
      }
      return false;
    } finally {
      overlay.dismiss();
    }
  }

  /// True when the currently-viewed org has an open vote on chain. Used after
  /// an org-record write to distinguish a threshold-1 auto-execute (no vote)
  /// from a threshold-N proposal that members still need to approve.
  Future<bool> _isOrgVoteOpen() async {
    if (_contact?.isOrgAccount != true || _selfProfile) return false;
    final addr = _contact?.publicosAddress;
    if (addr == null) return false;
    try {
      return await PublicOSGovernance.hasPendingVoteBy(
          addr.eip55With0x, PublicOS.myPublicosAddress);
    } catch (_) {
      return false;
    }
  }

  /// Opens the page-background sheet — the address-bar wallpaper button (edit
  /// mode, left of the edit toggle).
  void _showEditProfileBackgroundSheetInBrowser() {
    bool canEdit =
        (_selfProfile) || (_contact?.isOrgAccount == true && _isOrgMember);
    if (!canEdit || !_isEditMode) return;

    String? currentBackgroundImageUrl;
    if (_contact != null) {
      try {
        final bgRecord = _contact!.records.firstWhere((rec) =>
            rec.key == "_osux_profile_background_url_" && !rec.isExpired);
        if (bgRecord.value.trim().isNotEmpty) {
          currentBackgroundImageUrl = bgRecord.value;
        }
      } catch (e) {
        // If record not found or value is empty, URL remains null
        currentBackgroundImageUrl = null;
      }
    }

    showEditProfileBackgroundSheet(
      context,
      currentUrl: currentBackgroundImageUrl,
      onSave: _saveProfileBackgroundImageInBrowser,
    );
  }

  /// Writes (or, for an empty URL, deletes) the background record. Self →
  /// direct record write; org → governance vote.
  Future<void> _saveProfileBackgroundImageInBrowser(String imageUrl) async {
    bool canEdit =
        (_selfProfile) || (_contact?.isOrgAccount == true && _isOrgMember);
    if (!canEdit) return;

    try {
      bool success = false;

      // If URL is empty, delete the background record instead of saving empty value
      if (imageUrl.trim().isEmpty) {
        if (_selfProfile) {
          success = await PublicOSContacts.deleteRecord(
              "_osux_profile_background_url_");
        } else if (_contact?.isOrgAccount == true &&
            _isOrgMember &&
            _contact?.publicosAddress != null) {
          // Org record — route through governance (threshold-1 → deleted in
          // the startVote tx; threshold-N → vote now open).
          success = await PublicOSGovernance.startVoteDeleteRecord(
            _contact!.publicosAddress!,
            "_osux_profile_background_url_",
          );
        }
      } else {
        Record backgroundRecord = Record.asProfile(
          key: "_osux_profile_background_url_",
          value: imageUrl,
          icon: Icons.hide_image_outlined.codePoint,
        );

        if (_selfProfile) {
          success = await PublicOSContacts.setRecord(backgroundRecord);
        } else if (_contact?.isOrgAccount == true &&
            _isOrgMember &&
            _contact?.publicosAddress != null) {
          // Org record — route through governance (see note above).
          success = await PublicOSGovernance.startVoteSetRecord(
            _contact!.publicosAddress!,
            key: backgroundRecord.key,
            value: jsonEncode(backgroundRecord.toChainValue()),
            expiration:
                backgroundRecord.chainExpiration,
            recordType: BigInt.from(backgroundRecord.type.index),
            customType: backgroundRecord.subtype ?? '',
          );
        }
      }

      if (success) {
        final voteOpen = await _isOrgVoteOpen();
        await _loadContact(); // Full reload so the live vote shows
        if (mounted) {
          final l10n = context.l10n;
          String message;
          if (voteOpen) {
            message = l10n.browserVoteStartedMembersApprove;
          } else {
            message = imageUrl.trim().isEmpty
                ? l10n.browserProfileBackgroundRemoved
                : l10n.browserProfileBackgroundUpdated;
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message)),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(context.l10n.browserFailedUpdateBackground)),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(localizedError(context.l10n, e))),
        );
      }
    }
  }

  /// Returns the current tab path for display (e.g., "/Chat", "/Settings", "/AppName")
  /// Returns null when on profile tab (to hide the path)
  String? _getCurrentTabPath() {
    switch (_currentTab) {
      case BrowserTab.profile:
        return null; // Hide on profile tab
      case BrowserTab.chat:
        if (_contact?.isGroupChat == true) return context.l10n.browserGroupChat;
        // Prefer the selected inbox's on-chain label (tab_name) from
        // _chatTabs — same source as the switch-tab bottom sheet pills,
        // populated at :1117 from PublicOSXmtp.getAllAccountInboxIds.
        // Falls back to 'Chat' for XMTP-only stubs (the synthetic
        // _chatTabs entry built in _initializeChatState carries 'Chat').
        if (_selectedChatInboxId != null) {
          for (final chatTab in _chatTabs) {
            if ((chatTab['inboxId'] as String).toLowerCase() ==
                _selectedChatInboxId!.toLowerCase()) {
              final label = (chatTab['label'] as String?)?.trim() ?? '';
              if (label.isNotEmpty) return label;
              break;
            }
          }
        }
        return context.l10n.browserTabChat;
      case BrowserTab.settings:
        return context.l10n.browserTabSettings;
      case BrowserTab.app:
        return _currentApp?.displayName ?? context.l10n.browserTabApp;
      case BrowserTab.channel:
        return _currentCustomTabName ?? context.l10n.browserTabChannel;
      case BrowserTab.webview:
        return _currentCustomTabName ?? context.l10n.browserTabWeb;
      case BrowserTab.management:
        return context.l10n.browserTabManagement;
    }
  }

  /// Display name fallback chain: chain-resolved displayName → local
  /// displayName → truncated identifier ('Group chat' for topics). Keeps the
  /// header text slot non-empty across all loading states so the row layout
  /// is stable from first frame.
  String _displayedName() {
    final resolved = _contact?.displayName;
    if (resolved != null && resolved.trim().isNotEmpty) return resolved;
    if (widget.identifierType == ContactIdentifierType.xmtpConversationTopic) {
      return context.l10n.browserGroupChat;
    }
    final id = widget.identifier;
    if (id.length <= 12) return id;
    return '${id.substring(0, 6)}…${id.substring(id.length - 4)}';
  }

  /// The live `_osux_profile_background_url_` value, or null when unset.
  String? get _profileBackgroundUrl {
    for (final rec in _contact?.records ?? const <Record>[]) {
      if (rec.key == "_osux_profile_background_url_" &&
          !rec.isExpired &&
          rec.value.trim().isNotEmpty) {
        return rec.value;
      }
    }
    return null;
  }

  /// The plain banner URL the shared art geometry is built from; null for an
  /// NFT banner (its art keeps its own cover fit) or no banner.
  String? get _plainBannerUrl {
    if (_contact?.bannerIsBackground == true) return null;
    final url = _contact?.bannerUrl;
    return _contact?.nftBanner == null && url != null && url.isNotEmpty
        ? url
        : null;
  }

  /// No banner of any kind but a page background: the background stands in
  /// for the banner. On the profile tab the header paints
  /// the same pixels as Layer 0, so the page reads as one still image; on
  /// every other tab it is the banner, its top pinned to the top of the screen.
  /// Core's [Contact.bannerIsBackground] decides: a REMOVED
  /// banner (empty record) and one NEVER SET (no record, where `bannerUrl`
  /// answers the default banner) both fall back to the background.
  String? get _bgAsBannerUrl => _contact?.bannerIsBackground == true
      ? _contact!.backgroundUrl
      : null;

  void _artSizeReady() {
    if (mounted) setState(() {});
  }

  /// The live constellation stands in for the background image on the
  /// publicos org. Every tab: the header's background-as-
  /// banner is the top of the same animation, so switching tabs does not
  /// jump from the live page to the still. The full-page layer only ever
  /// shows on the profile tab anyway. Mobile only: desktop stays profile-only.
  bool get _showsLiveConstellation =>
      _contact != null &&
      ConstellationCanvas.isFor(
          displayName: _contact!.displayName,
          isOrg: _contact!.isOrgAccount);

  /// Banner + background geometry, one rule on every host
  /// ([ProfileArtLayout]): measured against the EXPANDED header,
  /// so the seam lines up at rest and the collapse only trims the banner.
  ProfileArtLayout? get _artLayout => ProfileArtLayout.compute(
        background:
            ProfileArtLayout.sizeOf(_profileBackgroundUrl, _artSizeReady),
        banner: ProfileArtLayout.sizeOf(_plainBannerUrl, _artSizeReady),
        viewWidth: _screenWidth,
        viewHeight: MediaQuery.sizeOf(context).height,
        boxHeight: _expandedHeaderHeight,
      );

  /// Layer 0: the page background, full screen, under the 30% scrim. Held
  /// back until both sizes are known so it never lands, then jumps.
  Widget _buildPageBackground(String url) {
    final layout = _artLayout;
    final bgHeight = layout?.backgroundHeight;
    if (layout == null ||
        bgHeight == null ||
        (_plainBannerUrl != null && layout.bannerAspect == null)) {
      return const SizedBox.shrink();
    }
    return ClipRect(
      child: Stack(
        children: [
          Positioned(
            left: layout.leftIn(_screenWidth),
            top: layout.top,
            width: layout.width,
            height: bgHeight,
            // The publicos org's profile runs the publicos.dev constellation
            // live in the still's place (an Easter egg). Same box, so
            // the banner seam and the header copy line up exactly.
            child: _showsLiveConstellation
                ? const ConstellationCanvas()
                : Image(
                    image: ZeroCachedImageProvider(url),
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.medium,
                  ),
          ),
          Positioned.fill(
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.3)),
          ),
        ],
      ),
    );
  }

  /// A plain banner placed by [_artLayout]: its bottom on the box's bottom
  /// (the collapse trims it from the top), its width the shared art width.
  /// Until its size is known: cover, bottom-anchored.
  Widget _placeBanner(Widget Function(BoxFit, Alignment) image) {
    final layout = _artLayout;
    if (layout == null || layout.bannerAspect == null) {
      return image(BoxFit.cover, Alignment.bottomCenter);
    }
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          left: layout.leftIn(_screenWidth),
          bottom: 0,
          width: layout.width,
          height: layout.bannerHeight,
          child: image(BoxFit.fill, Alignment.center),
        ),
      ],
    );
  }

  Widget _buildBanner(double progress) {
    final bannerUrl = _contact?.bannerUrl;
    final currentHeight = _calculateAddressBarHeight(progress);
    final scaffoldBg = Theme.of(context).scaffoldBackgroundColor;

    // NFT banner: a profile.banner.nft pointer wins over the plain URL. The
    // verified-art widget reads the fetchContact-computed verdict (image +
    // shimmer/sparkles). Note: the bottom-right sparkle spill is currently
    // clipped by the ClipRRect below — drop that clip on this branch if we want
    // it to read outside the strip.
    final nftBanner = _contact?.nftBanner;
    final nftBannerVerdict = _contact?.verifiedNftBannerData;
    final bannerHeroTag = 'banner_image_${bannerUrl ?? ''}';

    // Tap behaviour mirrors the avatar: a verified NFT banner opens the shared
    // NFT info dialog (no "use as avatar" — it's a banner, not your pfp); a
    // plain image banner focuses full-screen like the simple image avatar. An
    // NFT banner whose verdict hasn't been computed yet (first view) and an
    // empty banner are untappable.
    //
    // Only tappable on the profile tab. On every other tab the banner is
    // collapsed into the address bar; a tap there is meant for the address bar,
    // not to open the full-screen image / NFT dialog.
    final bool bannerTappable = _currentTab == BrowserTab.profile;
    VoidCallback? onBannerTap;
    if (bannerTappable && nftBanner != null && nftBannerVerdict != null) {
      onBannerTap = () => showNftInfoDialogFor(
            context,
            ref: nftBanner,
            cache: nftBannerVerdict,
            owner: _contact,
          );
    } else if (bannerTappable &&
        nftBanner == null &&
        _bgAsBannerUrl == null &&
        bannerUrl != null &&
        bannerUrl.isNotEmpty) {
      onBannerTap = () {
        Navigator.push(
          context,
          PageRouteBuilder(
            opaque: false,
            barrierColor: Colors.transparent,
            transitionDuration: const Duration(milliseconds: 300),
            reverseTransitionDuration: const Duration(milliseconds: 300),
            pageBuilder: (context, animation, secondaryAnimation) =>
                ImageOverlay(
              imageUrl: bannerUrl,
              heroTag: bannerHeroTag,
              onClose: () => Navigator.pop(context),
            ),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              return FadeTransition(opacity: animation, child: child);
            },
          ),
        );
      };
    }
    // Collapsed banner cedes focus: 0.4 collapsed → 1.0 expanded, riding the
    // expand animation. On top of (not replacing) the collapse shade gradient
    // in _buildAddressBar, which handles hiding content under the strip.
    //
    // The opaque backdrop under the AnimatedSwitcher below is what makes this
    // fade legal. Without it an Opacity paints straight onto the scrolling page
    // and the banner reads as see-through — which is exactly what NFT banners
    // did, because that branch was the one of the three that had no backing
    // fill of its own. It lives outside the switcher so no branch can forget it
    // and so a cross-fade between two banners cannot double-darken.
    final double bannerOpacity = (0.4 + 0.6 * progress).clamp(0.0, 1.0);
    final String? bgAsBanner = _bgAsBannerUrl;
    // Loading / no-banner: nothing but the backdrop, so the header is invisible
    // against the page (no network call, no default-banner flash).
    // Resolved: ZeroCachedImage on the URL. Fades when the URL changes
    // (null → local → chain) — the key must sit on the switcher's own child,
    // or AnimatedSwitcher compares two identical unkeyed wrappers and never
    // animates.
    final Widget content = nftBanner != null
        ? Opacity(
            key: ValueKey(
                'banner_nft_${_contact?.verifiedNftBanner ?? nftBanner.toCaip19()}'),
            opacity: bannerOpacity,
            child: NftBanner(contact: _contact!),
          )
        : bgAsBanner != null || bannerUrl == null || bannerUrl.isEmpty
            ? bgAsBanner != null
                // The background as the banner: Layer 0's own geometry (top
                // at the screen top), so the collapse only trims its bottom.
                // No collapse fade on the profile tab, where it must match
                // the identical picture below it.
                ? Opacity(
                    key: ValueKey('banner_bg_$bgAsBanner'),
                    opacity:
                        _currentTab == BrowserTab.profile ? 1 : bannerOpacity,
                    child: _buildPageBackground(bgAsBanner),
                  )
                : const SizedBox.expand(key: ValueKey('banner_empty'))
            : Opacity(
                key: ValueKey('banner_$bannerUrl'),
                opacity: bannerOpacity,
                child: _placeBanner(
                  (fit, alignment) => Hero(
                    tag: bannerHeroTag,
                    child: ZeroCachedImage(
                      imageUrl: bannerUrl,
                      fit: fit,
                      alignment: alignment,
                      fadeInDuration: Duration.zero,
                      fadeOutDuration: Duration.zero,
                      errorWidget: (context, url, error) =>
                          AnimatedStarryNight(isCollapsed: progress < 1.0),
                    ),
                  ),
                ),
              );

    return GestureDetector(
      onTap: onBannerTap,
      child: SizedBox(
      height: currentHeight,
      width: double.infinity,
      child: ClipRRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The opaque backing plate. Every banner branch fades against this
            // instead of against the scrolling page behind the header.
            ColoredBox(color: scaffoldBg),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              // Default AnimatedSwitcher layout sizes children to their
              // intrinsic size — that collapses the ZeroCachedImage. Force the
              // stack to expand so banner fills the full address-bar width.
              layoutBuilder: (currentChild, previousChildren) {
                return Stack(
                  fit: StackFit.expand,
                  alignment: Alignment.center,
                  children: <Widget>[
                    ...previousChildren,
                    if (currentChild != null) currentChild,
                  ],
                );
              },
              child: content,
            ),
          ],
        ),
      ),
      ),
    );
  }

  /// Hero tag derived from the widget's identifier so it's available immediately,
  /// before _contact is loaded. Matches the format from GlassContactIcon.contactHeroTag.
  String get _heroTag {
    String id = widget.identifier;
    // Normalize Ethereum addresses to EIP-55 to match GlassContactIcon.contactHeroTag
    if (widget.identifierType == ContactIdentifierType.publicosAddress &&
        id.startsWith('0x') &&
        id.length == 42) {
      try {
        id = EthereumAddress.fromHex(id).eip55With0x;
      } catch (_) {
        // Fallback to original if parsing fails
      }
    }
    return 'contact_$id';
  }

  Widget _buildAvatarAndName(double progress) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Single layout for loading and resolved states. GlassContactIcon paints
    // the scaffold-bg square when contact is null; the mini tab icon is driven
    // by _currentTab (known synchronously); display name + path use the
    // identifier fallback until the resolved data swaps in via fade. No
    // reflow, no missing mini icon.
    final hasContact = _contact != null;
    final avatarUrl = _contact?.avatarUrl;

    final avatarX = _calculateAvatarX(progress);
    final avatarY = _calculateAvatarY(progress);
    final avatarSize = _calculateAvatarSize(progress);

    // Get tab color
    final color = _getSelectedTabColor(theme);
    final iconColor = _getTextColor(color);

    // Mini icon size (like apps_view)
    final miniIconSize = (avatarSize * 0.35).clamp(16.0, 24.0);

    // When collapsed, leave space for close button; when expanded, go closer to edge
    final rightMargin =
        44.0 - (progress * 32.0); // 44 when collapsed, 12 when expanded

    return Positioned(
      left: avatarX,
      top: avatarY,
      right: rightMargin,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Avatar with mini tab icon overlay
          Container(
            decoration: BoxDecoration(
              // color: Theme.of(context).scaffoldBackgroundColor,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(
                    progress < 1 ? (1 - progress) * 40 : (progress * 11)),
                topRight: Radius.circular(
                    progress < 1 ? (1 - progress) * 40 : (progress * 11)),
                bottomLeft: Radius.circular(
                    progress < 1 ? (1 - progress) * 40 : (progress * 11)),
                bottomRight: Radius.circular(
                    progress < 1 ? (1 - progress) * 40 : (progress * 11)),
              ),
              // border: Border.all(
              //   color: Theme.of(context).scaffoldBackgroundColor,
              //   width: progress * 4,
              // ),
            ),
            child: GestureDetector(
              onTap: () {
                // Verified/resolvable NFT avatar → the dedicated NFT info
                // dialog instead of the plain full-screen image viewer.
                final nftContact = _contact;
                if (nftContact != null &&
                    nftContact.nftAvatar != null &&
                    nftContact.verifiedNftAvatarData != null) {
                  showNftInfoDialog(
                    context,
                    nftContact,
                    // Only offer "Use as avatar" on someone else's NFT — on your
                    // own profile the shown NFT is already your avatar.
                    onUseAsAvatar: _selfProfile ? null : _useNftAsAvatar,
                  );
                  return;
                }
                String? imageUrlToShow = avatarUrl;

                if (imageUrlToShow != null) {
                  final heroTag = _heroTag;
                  Navigator.push(
                    context,
                    PageRouteBuilder(
                      opaque: false,
                      barrierColor: Colors.transparent,
                      transitionDuration: const Duration(milliseconds: 300),
                      reverseTransitionDuration:
                          const Duration(milliseconds: 300),
                      pageBuilder: (context, animation, secondaryAnimation) =>
                          ImageOverlay(
                        imageUrl: imageUrlToShow!,
                        heroTag: heroTag,
                        onClose: () => Navigator.pop(context),
                      ),
                      transitionsBuilder:
                          (context, animation, secondaryAnimation, child) {
                        return FadeTransition(opacity: animation, child: child);
                      },
                    ),
                  );
                }
              },
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Main avatar — the canonical GlassContactIcon (NFT art,
                  // shape-by-class, phantom/XMTP badges); its internal
                  // ZeroCachedImage handles the image fade once a URL arrives.
                  // Self binds to AppStateNotifier so an in-app avatar/membership
                  // edit (routed through Core's write-through → selfContactUpdates)
                  // repaints live; other profiles render the fetched _contact.
                  ListenableBuilder(
                    listenable: AppStateNotifier.instance!,
                    builder: (context, _) {
                      final c = _selfProfile
                          ? (AppStateNotifier.currentMyContact ?? _contact)
                          : _contact;
                      return GlassContactIcon(
                        contact: c,
                        size: avatarSize,
                        // Pin the decode to the expanded (largest) size so the
                        // scroll-driven size animation doesn't re-target the
                        // image decoder every frame and strobe back to the
                        // initials placeholder. See GlassContactIcon.decodeSize.
                        decodeSize: _calculateAvatarSize(1.0),
                        heroTag: _heroTag,
                      );
                    },
                  ),
                  // Mini tab icon badge (bottom-right corner) - only show when not on profile/management
                  if (_currentTab != BrowserTab.profile &&
                      _currentTab != BrowserTab.management)
                    Positioned(
                      right: -4,
                      bottom: -6,
                      child: _currentTab == BrowserTab.app &&
                              _currentApp != null
                          ? Hero(
                              tag: 'app_${_currentApp!.appName}',
                              child: _buildMiniTabIcon(miniIconSize, isDark),
                            )
                          : _buildMiniTabIcon(miniIconSize, isDark),
                    ),
                ],
              ),
            ),
          ),
          // Name and action icons
          Expanded(
            child: GestureDetector(
              // Disabled while contact is loading — same hit target,
              // no-op tap so the row layout stays identical.
              onTap: hasContact
                  ? () {
                      HapticFeedback.lightImpact();
                      _showTabSelectionDropdown();
                    }
                  : null,
              child: Container(
                key: _tabContainerKey,
                padding: EdgeInsets.fromLTRB(
                    8, 12 + (progress * 8), 8 - (8 * progress), 8),
                child: Row(
                  children: [
                    // Display name with tab path
                    Expanded(
                      // The name travels 8px further down than the buttons as
                      // the header expands. Paint-only: a translate leaves the row's
                      // height, the buttons and the name's x untouched, and 0
                      // when collapsed keeps the collapsed bar as it was. (A
                      // top padding would move it only ~4px — the row centres
                      // the name against the taller buttons.)
                      child: Transform.translate(
                        offset: Offset(0, 8 * progress),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          // Baseline, not center: the name and the `/tab` path
                          // are different sizes, and centering puts the smaller
                          // path's baseline visibly higher.
                          // Stack / Fade / Slide all pass the baseline through.
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            // Display name — fades when the resolved name
                            // replaces the identifier fallback.
                            Flexible(
                              child: Builder(builder: (context) {
                                final displayName = _displayedName();
                                final shown = displayName.length > 16
                                    ? "${displayName.substring(0, 14)}.."
                                    : displayName;
                                return AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 220),
                                  // Left-align the crossfade. The default
                                  // layoutBuilder centers children in the Stack,
                                  // so when the resolved name (usually shorter)
                                  // replaces the truncated-identifier fallback on
                                  // landing, the incoming name paints centered
                                  // over the wider fallback and then snaps left
                                  // into its resting slot — reads as the name
                                  // "jumping in from the right". Pinning the
                                  // left edge makes it fade in place.
                                  layoutBuilder:
                                      (currentChild, previousChildren) => Stack(
                                    alignment: Alignment.centerLeft,
                                    children: <Widget>[
                                      ...previousChildren,
                                      if (currentChild != null) currentChild,
                                    ],
                                  ),
                                  transitionBuilder: (child, animation) =>
                                      FadeTransition(
                                          opacity: animation, child: child),
                                  child: Text(
                                    shown,
                                    key: ValueKey(shown),
                                    style: TextStyle(
                                      fontSize: _collapsedAvatarSize * 0.4 +
                                          (progress * 4),
                                      fontWeight: FontWeight.bold,
                                      color: iconColor,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                );
                              }),
                            ),
                            // Animated tab path. AnimatedSwitcher's default
                            // Stack-max layoutBuilder keeps the outgoing text's
                            // width reserved for the full 200ms exit, so the
                            // text fades+slides cleanly inside its old slot.
                            // The lagged `_displayedTab` (see field doc) holds
                            // incoming right-side icons back for that same
                            // 200ms so they don't compete for displayName's
                            // space mid-exit.
                            Padding(
                              padding: const EdgeInsets.only(bottom: 0.0),
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 200),
                                switchInCurve: Curves.easeOut,
                                // Linear out so the slide stays visible while
                                // the text fades — easeIn collapses opacity
                                // before any meaningful slide is perceived,
                                // making the exit feel like an instant pop.
                                switchOutCurve: Curves.linear,
                                transitionBuilder: (child, animation) {
                                  // Outgoing slides 40% of its own width to
                                  // the right (clipped by the Stack's
                                  // hardEdge, which reads as "vanishing into
                                  // the right"). Incoming keeps the subtle
                                  // 10% entry that the user already likes.
                                  final isOutgoing = animation.status ==
                                          AnimationStatus.reverse ||
                                      animation.status ==
                                          AnimationStatus.dismissed;
                                  final slideBegin = isOutgoing
                                      ? const Offset(0.4, 0)
                                      : const Offset(0.1, 0);
                                  return FadeTransition(
                                    opacity: animation,
                                    child: SlideTransition(
                                      position: Tween<Offset>(
                                        begin: slideBegin,
                                        end: Offset.zero,
                                      ).animate(animation),
                                      child: child,
                                    ),
                                  );
                                },
                                child: _getCurrentTabPath() != null
                                    ? Text(
                                        '/${_getCurrentTabPath()}',
                                        key: ValueKey(_getCurrentTabPath()),
                                        style: TextStyle(
                                          fontSize: _collapsedAvatarSize * 0.35 +
                                              (progress * 3),
                                          fontWeight: FontWeight.w500,
                                          color: iconColor.withValues(alpha: 0.6),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      )
                                    : const SizedBox.shrink(
                                        key: ValueKey('empty')),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Icons row (right side)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Sync indicator — failure/retry only. The syncing
                        // orbit is hidden on purpose:
                        // a background chain sync is not worth a spinner in
                        // the bar. Failure still shows while no retry runs.
                        SyncIndicator(
                          isSyncing: false,
                          hasFailed:
                              _chainSyncFailed && !_isSyncingFromChain,
                          size: 18,
                          onRetry: _retrySyncFromChain,
                        ),
                        const SizedBox(width: 8),
                        // Webview back chevron — shown on the webview-bearing
                        // tabs (webview / app) only while the embedded page has
                        // in-page history. Same _displayedTab AND-check as the
                        // neighbours so it tracks the tab-switch animation.
                        // Steps back inside the webview on both platforms (the
                        // iOS in-webview back affordance).
                        //
                        // It sits to the LEFT of the key glyph, and that order
                        // is the fix, not a preference: this row is pinned to
                        // the right edge, so adding or removing an item shifts
                        // everything to its LEFT and nothing to its right. The
                        // chevron comes and goes with `_webViewHasHistory` —
                        // every first in-page navigation — so with the key
                        // glyph before it the key jumped sideways on a page
                        // the user had not touched. Behind it, the key is
                        // fixed.
                        if (_webViewHasHistory &&
                            (_displayedTab == BrowserTab.webview ||
                                _displayedTab == BrowserTab.app)) ...[
                          _buildActionIcon(
                            icon: Icons.chevron_left_rounded,
                            onTap: () => _webViewController?.goBack(),
                            color: iconColor,
                            isDark: isDark,
                          ),
                          const SizedBox(width: 8),
                        ],
                        // Web-key indicator — whether this page is connected.
                        // Webview-bearing tabs only (there is no page to sign
                        // for on profile/chat/rss), same _displayedTab
                        // AND-check as its neighbours so it tracks the
                        // tab-switch animation. Tapping it opens the SITE's key
                        // permissions, not the keychain: permission is
                        // per-site, and the keychain carries delete/export/
                        // rename, which must never sit one mis-tap from a
                        // permission checkbox.
                        //
                        // Deliberately AFTER the back chevron — see its note.
                        if (_displayedTab == BrowserTab.webview ||
                            _displayedTab == BrowserTab.app) ...[
                          WebKeyIndicator(
                            connected: _webConnected,
                            activeAddress: _webActiveAccount,
                            origin: Uri.tryParse(_currentWebViewUrl ?? ''),
                            // The picker changed this site's permission. Bump
                            // the revision so the webview re-reads the set and
                            // tells the running page.
                            onGrantsChanged: () =>
                                setState(() => _grantsRevision++),
                            chainId: _webChainId,
                            onChainSelected: _switchWebChain,
                          ),
                          const SizedBox(width: 8),
                        ],
                        // Bookmark button - for app tabs. AND-checked against
                        // _displayedTab so it appears AFTER the path's 200ms
                        // exit when switching INTO app, and disappears
                        // synchronously when switching OUT.
                        if (_currentTab == BrowserTab.app &&
                            _displayedTab == BrowserTab.app &&
                            _currentApp != null) ...[
                          _buildActionIcon(
                            icon: _isCurrentAppBookmarked
                                ? Icons.bookmark_rounded
                                : Icons.bookmark_add_outlined,
                            onTap: _toggleBookmarkCurrentApp,
                            color: iconColor,
                            isDark: isDark,
                          ),
                          const SizedBox(width: 8),
                        ],
                        // The single Follow affordance for a channel — opens
                        // the add-to-list sheet, which adds it as a channel
                        // follow (tracked by record.key). There is no direct
                        // toggle into a special "Following" list. See `app`
                        // block for the `_displayedTab` AND-check rationale.
                        // Channel sign-in key
                        // — the feeds header's icon, on a channel tab: exists
                        // iff the channel has signalled sign-in (a row), glyph
                        // = the RULE's answer, tap → Allow · Deny · Forget.
                        // Left of the follow button, same tile, same
                        // 8*progress treatment.
                        if (_currentTab == BrowserTab.channel &&
                            _displayedTab == BrowserTab.channel &&
                            _signinPref != null) ...[
                          Padding(
                            padding: EdgeInsets.only(top: 8 * progress),
                            child: _buildActionIcon(
                              icon: _signinEffective
                                  ? Icons.vpn_key_rounded
                                  : Icons.vpn_key_off_rounded,
                              onTap: _showSigninMenu,
                              color: _signinEffective
                                  ? iconColor
                                  : iconColor.withValues(alpha: 0.45),
                              isDark: isDark,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (_currentTab == BrowserTab.channel &&
                            _displayedTab == BrowserTab.channel &&
                            _currentCustomTabName != null) ...[
                          // Same 8*progress treatment as the profile-only
                          // buttons: channel tabs expand now, and without it
                          // this icon sits 8px above its row neighbors at
                          // full expansion (collapsed is unchanged — 8*0).
                          Padding(
                            padding: EdgeInsets.only(top: 8 * progress),
                            child: _buildActionIcon(
                              icon: _isCurrentRssFeedInList
                                  ? Icons.bookmark_added_rounded
                                  : Icons.bookmark_add_outlined,
                              onTap: _showAddToListBottomSheet,
                              color: iconColor,
                              isDark: isDark,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        // QR + Share ("Copy profile link") + Flag live in the
                        // profile "…" menu (otherwise there are too many
                        // buttons on an org you belong to). See below Edit.
                        //
                        // Every profile-only button pads `top: 8*progress` (not
                        // a constant) so it doesn't inflate the collapsed
                        // action row: the row is center-aligned, and that
                        // inflation pushed the dropdown + avatar ~4px below
                        // where they sit on the management tab. Collapsed
                        // matches management exactly; expanded keeps the +8
                        // offset. Account-based Follow — profile tab, other
                        // accounts only (following yourself is not a thing).
                        // Additive to the channel-tab heart, which is a
                        // separate single-feed affordance. `_displayedTab`
                        // AND-check per the `app` block. Star — profile tab,
                        // other accounts only, never the publicos org. Left of
                        // the follow button. Fills yellow with a bounce and a
                        // few confetti when turned on.
                        if (_currentTab == BrowserTab.profile &&
                            _displayedTab == BrowserTab.profile &&
                            _starShown) ...[
                          Padding(
                            padding:
                                EdgeInsets.only(right: 8.0, top: 8 * progress),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: StarButton(
                                starred: _isStarred,
                                onTap: _toggleStarCurrentAccount,
                                idleColor: _pillGlyph(iconColor),
                                pill: _glassPill,
                              ),
                            ),
                          ),
                        ],
                        if (_currentTab == BrowserTab.profile &&
                            _displayedTab == BrowserTab.profile &&
                            _contact?.publicosAddress != null &&
                            !_selfProfile) ...[
                          Padding(
                            padding:
                                EdgeInsets.only(right: 8.0, top: 8 * progress),
                            // No spinner while toggling — local DB write only.
                            // The icon stays put and flips once the follow lands.
                            child: _buildActionIcon(
                              icon: _isFollowingAccount
                                  ? Icons.how_to_reg_rounded
                                  : Icons.person_add_alt_1_rounded,
                              onTap: _toggleFollowCurrentAccount,
                              color: _isFollowingAccount
                                  ? Theme.of(context).colorScheme.primary
                                  : iconColor,
                              isDark: isDark,
                            ),
                          ),
                        ],
                        // Page background — edit mode only, directly left of
                        // the edit toggle. An ActionSlot (desktop's DeckSlot),
                        // so entering edit mode slides QR/Share left while it
                        // fades in, instead of the row jumping (horizontal only).
                        ActionSlot(
                          child: _currentTab == BrowserTab.profile &&
                                  _displayedTab == BrowserTab.profile &&
                                  _isEditMode &&
                                  (_selfProfile ||
                                      (_contact?.isOrgAccount == true &&
                                          _isOrgMember))
                              ? Padding(
                                  padding: EdgeInsets.only(
                                      right: 8.0, top: 8 * progress),
                                  child: _buildActionIcon(
                                    icon: Icons.wallpaper_rounded,
                                    onTap:
                                        _showEditProfileBackgroundSheetInBrowser,
                                    color: iconColor,
                                    isDark: isDark,
                                  ),
                                )
                              : null,
                        ),
                        // Edit toggle — editable profiles only (own profile or
                        // an org you're a member of). Replaces the old
                        // bottom-right edit FAB. In edit mode it's a red X on a
                        // light-red chip to leave edit mode.
                        if (_currentTab == BrowserTab.profile &&
                            _displayedTab == BrowserTab.profile &&
                            // In the "…" menu instead when the row would pass
                            // four buttons (see [_editInOverflow]).
                            !_editInOverflow &&
                            (_selfProfile ||
                                (_contact?.isOrgAccount == true &&
                                    _isOrgMember))) ...[
                          Padding(
                            padding: EdgeInsets.only(right: 8.0, top: 8 * progress),
                            child: _buildActionIcon(
                              icon: _isEditMode
                                  ? Icons.edit_off_rounded
                                  : Icons.edit_rounded,
                              onTap: () =>
                                  setState(() => _isEditMode = !_isEditMode),
                              // Desktop: the glyph turns red, no red chip.
                              color: _isEditMode
                                  ? Theme.of(context).colorScheme.error
                                  : iconColor,
                              isDark: isDark,
                            ),
                          ),
                        ],
                        // "…" — the profile's overflow menu, right of edit,
                        // left of the tabs chevron. Holds
                        // QR · Copy profile link · Flag (others' profiles
                        // only), in the pills' frosted glass. Mobile, profile
                        // tab only; every other tab keeps its own buttons.
                        if (_currentTab == BrowserTab.profile &&
                            _displayedTab == BrowserTab.profile &&
                            _contact?.publicosAddress != null) ...[
                          Padding(
                            key: _profileMoreKey,
                            padding:
                                EdgeInsets.only(right: 8.0, top: 8 * progress),
                            child: _buildActionIcon(
                              icon: Icons.more_horiz_rounded,
                              onTap: _openProfileMoreMenu,
                              color: iconColor,
                              isDark: isDark,
                            ),
                          ),
                        ],
                        // Settings gear — chat tabs only. Opens the
                        // conversation-settings sheet (consent / shared media /
                        // hidden debug). Takes the bookmark slot, left of the
                        // tab-switcher chevron. `_displayedTab` AND-check tracks
                        // the tab-switch animation like the bookmark/follow
                        // neighbors. Hidden until the chat reports a resolved
                        // topic, so a brand-new DM shows no dead button
                        // (mirrors the old input-bar gear's disabled state).
                        if (_currentTab == BrowserTab.chat &&
                            _displayedTab == BrowserTab.chat &&
                            _chatSettingsOpener != null) ...[
                          _buildActionIcon(
                            icon: Icons.settings_outlined,
                            onTap: _chatSettingsOpener!,
                            color: iconColor,
                            isDark: isDark,
                          ),
                          const SizedBox(width: 8),
                        ],
                        // Dropdown indicator with Phigital styling
                        Padding(
                          padding: EdgeInsets.only(left: 6, top: 8 * progress),
                          child: _glassPill(
                            SizedBox(
                              width: 28,
                              height: 28,
                              child: Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 16,
                                color: Colors.white.withValues(alpha: 0.92),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds a consistent action icon button with Phigital styling
  /// Desktop's deck-button chrome on mobile (the frosted-glass pill):
  /// desktop `GlassPill` fully on, 10-sigma blur
  /// over a 30% black wash, radius 8, so the glyph reads on any banner or
  /// background. The address-bar row always sits on the header art, so here
  /// the pill never switches off.
  Widget _glassPill(Widget child) {
    const radius = BorderRadius.all(Radius.circular(8));
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.30),
            borderRadius: radius,
          ),
          child: child,
        ),
      ),
    );
  }

  /// Glyph colour on the pill: desktop's docked foreground (92% white), unless
  /// the caller passes a state colour (followed, editing, signed in).
  Color _pillGlyph(Color color) =>
      color == _getTextColor(_getSelectedTabColor(Theme.of(context)))
          ? Colors.white.withValues(alpha: 0.92)
          : color;

  Widget _buildActionIcon({
    required IconData icon,
    required VoidCallback onTap,
    required Color color,
    bool isDark = false,
  }) {
    return GestureDetector(
      // The 28x28 chip is the target, not the glyph inside it. A
      // GestureDetector defaults to `deferToChild`, and a Container built from
      // a `decoration` (rather than a `color`) is a DecoratedBox, which does
      // not hit-test itself -- so without this the tappable area was only the
      // icon. Same fix the desktop key indicator needed.
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.only(left: 6),
        child: _glassPill(
          SizedBox(
            width: 28,
            height: 28,
            child: Icon(icon, size: 16, color: _pillGlyph(color)),
          ),
        ),
      ),
    );
  }

  /// Builds the mini tab icon overlay for the avatar
  // Tab-type mini badge — monochrome glass notch (same recipe as the shared
  // `TabTypeBadge` used by the tab-switcher + Manage tabs sheets): solid
  // surfaceDeep rounded-square, borderMedium hairline, starkWhite glyph. The
  // glyph carries the type, never the color (grey-palette rule).
  // App tabs keep their icon art.
  Widget _buildMiniTabIcon(double size, bool isDark) {
    final tokens = GlassTokens.of(context);

    // Determine icon/image based on current tab
    Widget iconContent;

    if (_currentTab == BrowserTab.chat) {
      iconContent = Icon(
        Icons.chat_bubble_rounded,
        size: size * 0.6,
        color: tokens.starkWhite,
      );
    } else if (_currentTab == BrowserTab.app && _currentApp != null) {
      if (_currentApp!.icon != null && _currentApp!.icon!.isNotEmpty) {
        iconContent = ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.2),
          child: ZeroCachedImage(
            imageUrl: _currentApp!.icon!,
            width: size * 0.7,
            height: size * 0.7,
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) => Icon(
              Icons.apps_rounded,
              size: size * 0.6,
              color: tokens.starkWhite,
            ),
          ),
        );
      } else {
        iconContent = Icon(
          Icons.apps_rounded,
          size: size * 0.6,
          color: tokens.starkWhite,
        );
      }
    } else if (_currentTab == BrowserTab.webview ||
        _currentTab == BrowserTab.channel) {
      iconContent = Icon(
        _currentTab == BrowserTab.channel
            ? Icons.rss_feed_rounded
            : Icons.language_rounded,
        size: size * 0.6,
        color: tokens.starkWhite,
      );
    } else if (_currentTab == BrowserTab.settings) {
      iconContent = Icon(
        Icons.settings_rounded,
        size: size * 0.6,
        color: tokens.starkWhite,
      );
    } else if (_currentTab == BrowserTab.management) {
      iconContent = Icon(
        Icons.admin_panel_settings_rounded,
        size: size * 0.6,
        color: tokens.starkWhite,
      );
    } else {
      iconContent = Icon(
        Icons.person_rounded,
        size: size * 0.6,
        color: tokens.starkWhite,
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tokens.surfaceDeep,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Center(child: iconContent),
    );
  }

  Widget _buildAddressBar() {
    final currentProgress = _profileAnimation.value;

    // Calculate the base height of the address bar as it animates (banner portion)
    final double baseAnimatedHeaderHeight =
        _calculateAddressBarHeight(currentProgress);

    // Calculate the Y position of the bottom edge of the avatar
    final double avatarCurrentSize = _calculateAvatarSize(currentProgress);
    final double avatarCurrentY = _calculateAvatarY(currentProgress);
    final double avatarBottomEdgeY = avatarCurrentY + avatarCurrentSize;

    // The new height for the Container should be enough to contain either the banner or the full avatar.
    final double adjustedHeaderHeight =
        baseAnimatedHeaderHeight > avatarBottomEdgeY
            ? baseAnimatedHeaderHeight
            : avatarBottomEdgeY + (currentProgress * 8);

    final fixedTopPadding = _statusBarHeight + 9;
    final avatarUrl = _contact?.avatarUrl;

    return Container(
      height: adjustedHeaderHeight, // Use the new dynamically adjusted height
      // decoration: BoxDecoration(
      //   color: Colors.blue,

      // ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _buildBanner(currentProgress),

          // Collapse shade — a dark gradient over the banner that fades IN as
          // the header collapses (0 expanded → ~0.12 collapsed). It stacks with
          // _buildBanner's own collapse fade (0.4 → 1.0, against that method's
          // opaque backdrop — see there); this wash keeps the avatar/name/
          // buttons legible against the banner slice and gives the collapsed
          // strip its shaded look. Sits between the banner and the foreground
          // (avatar/name/buttons), and never eats touches.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: baseAnimatedHeaderHeight,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0),
                      // None over a background standing in for the banner on
                      // the profile tab: it would seam against Layer 0.
                      Colors.black.withValues(
                          alpha: _currentTab == BrowserTab.profile &&
                                  _bgAsBannerUrl != null
                              ? 0
                              : (1 - currentProgress) * 0.12),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Status-bar frost — a soft, progressive blur over just the top strip
          // (height = status bar) so the OS clock/battery icons stay legible
          // against a busy banner. Built as a few stacked blur passes, each a
          // ClipRect child anchored at the top and getting shorter — so the blur
          // compounds toward the very top and eases out to a light haze at the
          // strip's bottom (no hard cutoff). NOT a ShaderMask-masked
          // BackdropFilter: a BackdropFilter inside a ShaderMask samples that
          // mask layer's empty backdrop and blurs nothing. IgnorePointer so it
          // never eats touches.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: _statusBarHeight,
            child: IgnorePointer(
              child: Stack(
                children: [
                  // 8 evenly-spaced passes, each a frame shorter than the last,
                  // so the blur count ramps linearly from 1 at the strip's
                  // bottom to 8 at the very top — a smooth gradient. More passes
                  // + a lighter per-pass sigma = more gradual (and more cost).
                  // This 8-pass status-bar frost
                  // is 8 saveLayer+blur passes/frame, paid continuously while
                  // a platform view (WebView) is on-screen. Commented out to
                  // keep the WebView's frame rate; restore if the frost is
                  // missed.
                  // for (int i = 0; i < 8; i++)
                  //   Positioned(
                  //     top: 0,
                  //     left: 0,
                  //     right: 0,
                  //     height: _statusBarHeight * (8 - i) / 8,
                  //     child: ClipRect(
                  //       child: BackdropFilter(
                  //         filter: ImageFilter.blur(sigmaX: 0+((i+1)*.24), sigmaY: 0+((i+1)*.24)),
                  //         child: const SizedBox.expand(),
                  //       ),
                  //     ),
                  //   ),
                ],
              ),
            ),
          ),

          // Close button (X) - top right, Phigital styling
          Positioned(
            right:
                8 + (currentProgress * 4), // Move closer to edge as it expands
            top: fixedTopPadding +
                ((_collapsedHeaderHeightBase - 36) / 2) -
                (currentProgress * 16),
            // The action row's frosted-glass pill.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.pop(context),
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: _glassPill(
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: Colors.white.withValues(alpha: 0.92),
                    ),
                  ),
                ),
              ),
            ),
          ),

          _buildAvatarAndName(currentProgress),
          // Banner edit pencil — an at-rest affordance only. Above 90%
          // expansion it fades from full → 0 (reaching 0 at progress 0.9);
          // below 0.9 it's omitted from the tree entirely, so once the header
          // starts collapsing the pencil disappears and can't catch touches
          // meant for the avatar/name/buttons or the content beneath.
          if (_currentTab == BrowserTab.profile &&
              _isEditMode &&
              currentProgress > 0.9 &&
              ((_selfProfile) ||
                  (_contact?.isOrgAccount == true && _isOrgMember)))
            Positioned(
              right: kHorizontalPadding - 16,
              top: baseAnimatedHeaderHeight - 36,
              child: Opacity(
                opacity: ((currentProgress - 0.9) / 0.1).clamp(0.0, 1.0),
                child: _buildEditButton(
                  context,
                  () {
                    HapticFeedback.lightImpact();
                    _showEditImageSheet(context, 'banner', _contact?.bannerUrl);
                  },
                ),
              ),
            ),
          // Avatar edit pencil — same at-rest fade + tree-removal as the banner
          // pencil (full → 0 over 100%→90%, omitted below 0.9).
          if (_currentTab == BrowserTab.profile &&
              _isEditMode &&
              currentProgress > 0.9 &&
              ((_selfProfile) ||
                  (_contact?.isOrgAccount == true && _isOrgMember)))
            Positioned(
              left: avatarCurrentSize - 2, // Corrected from: avatarCurrentSize
              bottom: 4,
              child: Opacity(
                opacity: ((currentProgress - 0.9) / 0.1).clamp(0.0, 1.0),
                child: _buildEditButton(
                  context,
                  () {
                    HapticFeedback.lightImpact();
                    _showEditImageSheet(context, 'avatar', avatarUrl);
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showTabSelectionDropdown() async {
    _showTabPickerSheet();
  }

  /// Open the manage-profile-tabs sheet and, on save, reload the contact and
  /// fall back to the profile tab if the open custom tab was just deleted.
  /// Shared by the tab-switcher sheet's "Manage tabs" action.
  Future<void> _openManageProfileTabs() async {
    HapticFeedback.lightImpact();
    final result = await showManageProfileTabsSheet(
      context: context,
      contact: _selfProfile ? null : _contact,
      isOrgMember: _isOrgMember,
    );
    if (result == true) {
      await _loadContact();
      if (_currentCustomTabName != null &&
          _currentTab == BrowserTab.webview) {
        final currentCustomTabExists = _profileTabs.any((tab) =>
            (tab.metadata['name'] as String?) == _currentCustomTabName);
        if (!currentCustomTabExists) {
          setState(() {
            _currentCustomTabName = null;
            _currentTab = BrowserTab.profile;
          });
          _updateProfileAnimationState();
        }
      }
    }
  }

  /// Glass-styled tab picker. Sections render with uppercase headers when
  /// they hold more than one item; singletons (Profile / Management /
  /// Settings) sit on their own without a label.
  ///
  /// The sheet recomputes its sections from live page state on every
  /// [_tabDataVersion] bump, so a sheet that is open while the chain sync
  /// lands picks up fresh labels/rows instantly.
  void _showTabPickerSheet() {
    // Don't open on nothing; once open, updates flow via _tabDataVersion.
    if (_buildTabSections().every((s) => s.items.isEmpty)) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (sheetCtx) {
        final tokens = GlassTokens.of(sheetCtx);
        return Container(
          decoration: BoxDecoration(
            color: tokens.surfaceDeep,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(color: tokens.borderSubtle, width: 1),
          ),
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetCtx).size.height * 0.7,
              ),
              child: ValueListenableBuilder<int>(
                valueListenable: _tabDataVersion,
                builder: (_, __, ___) =>
                    _buildTabPickerBody(sheetCtx, tokens),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTabPickerBody(BuildContext sheetCtx, GlassTokens tokens) {
    final visibleSections =
        _buildTabSections().where((s) => s.items.isNotEmpty).toList();

    final entries = <({String? header, TabItem? item})>[];
    for (final section in visibleSections) {
      final label = _sectionLabel(section);
      if (label != null && section.items.length > 1) {
        entries.add((header: label, item: null));
      }
      for (final item in section.items) {
        entries.add((header: null, item: item));
      }
    }

    // "Manage tabs" footer shows on editable profiles (own profile or a member
    // org), independent of which tab is current.
    final bool canEdit =
        _selfProfile || (_contact?.isOrgAccount == true && _isOrgMember);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: tokens.borderMedium,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
          child: Row(
            children: [
              Text(
                context.l10n.browserSwitchTab,
                style: TextStyle(
                  fontFamily: 'SpaceGrotesk',
                  color: tokens.starkWhite,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.close_rounded,
                    color: tokens.starkWhite),
                onPressed: () => Navigator.pop(sheetCtx),
              ),
            ],
          ),
        ),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 12),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              if (entry.header != null) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                  child: Text(
                    entry.header!,
                    style: TextStyle(
                      fontFamily: 'SpaceGrotesk',
                      color: tokens.textDim,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                    ),
                  ),
                );
              }
              return _buildTabPickerRow(entry.item!, tokens);
            },
          ),
        ),
        // Manage tabs — always available on editable profiles (own
        // profile / member org). Replaces the edit-tabs FAB; opens
        // the manage-profile-tabs sheet without entering edit mode.
        if (canEdit)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: GestureDetector(
              onTap: () {
                Navigator.pop(sheetCtx);
                _openManageProfileTabs();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: tokens.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: tokens.borderSubtle),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.list_alt_rounded,
                        size: 18, color: tokens.starkWhite),
                    const SizedBox(width: 8),
                    Text(
                      context.l10n.browserManageTabs,
                      style: TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        color: tokens.starkWhite,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  String? _sectionLabel(TabSection section) {
    final first = section.items.first;
    if (first.isChatTab) return context.l10n.browserSectionChats;
    if (first.isAppTab) return context.l10n.browserSectionApps;
    if (first.isCustomTab) return context.l10n.browserSectionTabs;
    return null;
  }

  Widget _buildTabPickerRow(TabItem item, GlassTokens tokens) {
    IconData fallbackIcon;
    Widget? imageContent;

    if (item.isBrowserTab && item.browserTab != null) {
      switch (item.browserTab!) {
        case BrowserTab.profile:
          fallbackIcon = Icons.person_rounded;
          break;
        case BrowserTab.chat:
          fallbackIcon = Icons.chat_bubble_outline_rounded;
          break;
        case BrowserTab.settings:
          fallbackIcon = Icons.settings_outlined;
          break;
        case BrowserTab.management:
          fallbackIcon = Icons.admin_panel_settings_rounded;
          break;
        case BrowserTab.webview:
          fallbackIcon = Icons.language_rounded;
          break;
        case BrowserTab.channel:
          fallbackIcon = Icons.rss_feed_rounded;
          break;
        case BrowserTab.app:
          fallbackIcon = Icons.apps_rounded;
          break;
      }
    } else if (item.isChatTab) {
      fallbackIcon = Icons.chat_bubble_outline_rounded;
    } else if (item.isAppTab && item.appBookmark != null) {
      fallbackIcon = Icons.apps_rounded;
      final iconUrl = item.appBookmark!.icon;
      if (iconUrl != null && iconUrl.isNotEmpty) {
        imageContent = ZeroCachedImage(
          imageUrl: iconUrl,
          width: 36,
          height: 36,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) =>
              Icon(fallbackIcon, size: 18, color: tokens.starkWhite),
        );
      }
    } else if (item.isCustomTab && item.record != null) {
      final isRss = item.record!.routerSubtype == RouterSubtype.channel;
      fallbackIcon = isRss ? Icons.rss_feed_rounded : Icons.language_rounded;
      imageContent = TabIconWidget(record: item.record!, size: 36);
    } else {
      fallbackIcon = Icons.tab_rounded;
    }

    final iconBox = Container(
      width: 36,
      height: 36,
      clipBehavior: imageContent != null ? Clip.antiAlias : Clip.none,
      decoration: BoxDecoration(
        color: tokens.glassFill,
        borderRadius: BorderRadius.circular(10),
      ),
      child: imageContent ??
          Center(child: Icon(fallbackIcon, size: 18, color: tokens.starkWhite)),
    );

    // Notch the tab-type badge into the bottom-right corner whenever the icon
    // shows artwork (custom-tab favicons, app icons) — so the type reads at a
    // glance even when the art doesn't, matching the address-bar avatar
    // (_buildMiniTabIcon) and the Manage tabs sheet. `fallbackIcon` is already
    // the type glyph for those branches (rss/language for custom, apps for an
    // app). Browser tabs (profile/chat/settings/…) already show a type glyph as
    // their main icon, so they get no redundant badge. The 40×40 box is uniform
    // across all rows so labels stay aligned.
    final leading = SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          iconBox,
          if (imageContent != null)
            Positioned(
              right: -2,
              bottom: -2,
              child: TabTypeBadge(icon: fallbackIcon),
            )
          // The inbox this device has loaded gets the keychain's "loaded key"
          // glyph in the same notch, so the dimmed row reads
          // as "this is you", not as broken. Chat rows carry no artwork, so
          // the notch is free.
          else if (item.isLoadedInbox)
            const Positioned(
              right: -2,
              bottom: -2,
              child: TabTypeBadge(icon: Icons.sim_card_rounded),
            ),
        ],
      ),
    );

    // The inbox this device has loaded: the SAME row, dimmed, and inert - a
    // tap does nothing. A null InkWell.onTap also kills the ripple.
    final disabled = item.isLoadedInbox;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Opacity(
        opacity: disabled ? 0.4 : 1.0,
        child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: disabled
              ? null
              : () {
                  Navigator.pop(context);
                  _handleTabSelection(item);
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.label,
                    style: TextStyle(
                      fontFamily: 'SpaceGrotesk',
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: tokens.starkWhite,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: tokens.textDim,
                ),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }

  List<TabSection> _buildTabSections() {
    final sections = <TabSection>[];

    // 1. Profile tab first (always at top) - exclude if currently selected
    if (!_isCurrentTab(BrowserTab.profile, null, null)) {
      final profileTab = _tabs.firstWhere(
          (tab) => tab.tab == BrowserTab.profile,
          orElse: () => _TabInfo(tab: BrowserTab.profile, label: 'Profile'));
      sections.add(TabSection(
        items: [
          TabItem(
            browserTab: profileTab.tab,
            label: context.l10n.browserTabProfile,
          )
        ],
      ));
    }

    // 2. Chat tabs - exclude when currently selected. Groups get a single
    // static "Group chat" pill mapped to BrowserTab.chat (no per-inbox
    // semantics — they're one conversation keyed by topic). DMs keep
    // per-inbox pills built from _chatTabs (multi-session peers can still
    // pick which session to message).
    if (_contact?.isGroupChat == true) {
      if (!_isCurrentTab(BrowserTab.chat, null, null)) {
        sections.add(TabSection(
          items: [
            TabItem(
              browserTab: BrowserTab.chat,
              label: context.l10n.browserGroupChat,
            ),
          ],
          needsDivider: sections.isNotEmpty,
        ));
      }
    } else {
      // Drop only the tab you are already on. The inbox this device has
      // loaded STAYS (flagged `isSelf`) and renders dimmed + inert, so it
      // reads as "this one is you" instead of vanishing.
      final availableChatTabs = _chatTabs.where((chatTab) {
        final tabInboxId = chatTab['inboxId'] as String;
        final isCurrentlySelected =
            _selectedChatInboxId != null && tabInboxId == _selectedChatInboxId;
        return !isCurrentlySelected;
      }).toList();

      if (availableChatTabs.isNotEmpty) {
        final chatItems = availableChatTabs.map((chatTab) {
          final inboxId = chatTab['inboxId'] as String;
          final label = chatTab['label'] as String? ?? context.l10n.browserTabChat;
          return TabItem(
            inboxId: inboxId,
            label: label,
            isLoadedInbox: chatTab['isSelf'] == true,
          );
        }).toList();

        sections.add(TabSection(
          items: chatItems,
          needsDivider: sections.isNotEmpty,
          isScrollable: true,
        ));
      }
    }

    // 3. Web tabs (custom profile tabs - max 5, scrollable if more) - exclude current custom tab
    final availableProfileTabs = _profileTabs.where((record) {
      final tabName = record.metadata['name'] as String?;
      return tabName != _currentCustomTabName;
    }).toList();

    if (availableProfileTabs.isNotEmpty) {
      final profileItems = availableProfileTabs.map((record) {
        return TabItem(
          record: record,
          label: record.metadata['name'] as String? ?? context.l10n.browserUnnamedTab,
        );
      }).toList();

      sections.add(TabSection(
        items: profileItems,
        needsDivider: sections.isNotEmpty,
        isScrollable: true,
      ));
    }

    // 3.5. App tabs (registered apps with URLs) - exclude current app
    final availableAppTabs = _contactApps.where((app) {
      return _currentApp == null || app.appName != _currentApp!.appName;
    }).toList();

    if (availableAppTabs.isNotEmpty) {
      final appItems = availableAppTabs.map((app) {
        return TabItem(
          appBookmark: app,
          label: app.displayName,
        );
      }).toList();

      sections.add(TabSection(
        items: appItems,
        needsDivider: sections.isNotEmpty,
        isScrollable: true,
      ));
    }

    // 4. Management tab (only for group accounts) - exclude if currently selected
    if (_contact?.isOrgAccount == true &&
        !_isCurrentTab(BrowserTab.management, null, null)) {
      final managementTab = _tabs.firstWhere(
          (tab) => tab.tab == BrowserTab.management,
          orElse: () =>
              _TabInfo(tab: BrowserTab.management, label: 'Management'));
      sections.add(TabSection(
        items: [
          TabItem(
            browserTab: managementTab.tab,
            label: context.l10n.browserTabManagement,
          )
        ],
        needsDivider: sections.isNotEmpty,
      ));
    }

    // 5. Settings tab (always at bottom) - exclude if currently selected, or if
    // viewing myself (the tab is gone; `orElse` below would resurrect it).
    if (!_isViewingSelf && !_isCurrentTab(BrowserTab.settings, null, null)) {
      final settingsTab = _tabs.firstWhere(
          (tab) => tab.tab == BrowserTab.settings,
          orElse: () => _TabInfo(tab: BrowserTab.settings, label: 'Settings'));
      sections.add(TabSection(
        items: [
          TabItem(
            browserTab: settingsTab.tab,
            label: context.l10n.browserTabSettings,
          )
        ],
        needsDivider: sections.isNotEmpty,
      ));
    }

    return sections;
  }

  bool _isCurrentTab(
      BrowserTab? browserTab, String? inboxId, String? customTabName) {
    if (browserTab != null) {
      return _currentTab == browserTab &&
          _selectedChatInboxId == null &&
          _currentCustomTabName == null;
    }
    if (inboxId != null) {
      return _currentTab == BrowserTab.chat && _selectedChatInboxId == inboxId;
    }
    if (customTabName != null) {
      return (_currentTab == BrowserTab.webview ||
              _currentTab == BrowserTab.channel) &&
          _currentCustomTabName == customTabName;
    }
    return false;
  }

  bool _matchesLandingTab(TabItem tabItem) {
    final landing = _landingTabItem ?? _buildLandingTabItem();
    if (tabItem.isBrowserTab && landing.isBrowserTab) {
      return tabItem.browserTab == landing.browserTab;
    }
    if (tabItem.isChatTab && landing.isChatTab) {
      return tabItem.inboxId == landing.inboxId;
    }
    if (tabItem.isAppTab && landing.isAppTab) {
      return tabItem.appBookmark == landing.appBookmark;
    }
    if (tabItem.isCustomTab && landing.isCustomTab) {
      return tabItem.record == landing.record;
    }
    return false;
  }

  void _handleTabSelection(TabItem tabItem) {
    // The loaded inbox is shown but inert: a tap does nothing.
    // Belt for any caller that hands one over anyway.
    if (tabItem.isLoadedInbox) return;
    _hasNavigatedAway = !_matchesLandingTab(tabItem);
    // Clear the history mirror on every tab switch so a newly-shown webview
    // starts with no chevron / Tier 1 until its own controller re-reports via
    // onCanGoBackChanged. Closes the brief window where switching webview→webview
    // would inherit the previous tab's "has history". The controller handle is
    // intentionally NOT nulled: it's replaced on remount (onControllerCreated)
    // and is always gated behind _webViewCanGoBack + the tab-type check before
    // any goBack(), so a stale handle is inert; nulling it would instead break
    // the case where the PublicOSWebView State is reused (two tabs, same URL →
    // same ValueKey → onControllerCreated never re-fires).
    _webViewCanGoBack = false;
    // Trigger tab switch animation
    _tabSwitchAnimationController.reset();
    _tabSwitchAnimationController.forward();

    if (tabItem.isBrowserTab && tabItem.browserTab != null) {
      _selectTab(tabItem.browserTab!);
      setState(() {
        _selectedChatInboxId =
            null; // Clear selected chat inbox when a static tab is chosen
        _currentApp = null; // Clear current app
        _isCurrentAppBookmarked = false; // Clear bookmark state
      });
    } else if (tabItem.isChatTab && tabItem.inboxId != null) {
      setState(() {
        _currentTab = BrowserTab.chat;
        _selectedChatInboxId = tabItem.inboxId;
        _currentCustomTabName = null; // Clear custom web tab name
        _currentApp = null; // Clear current app
        _isCurrentAppBookmarked = false; // Clear bookmark state
        _error = null;
        if (_isEditMode) {
          _isEditMode = false;
        }
      });
      _updateProfileAnimationState();
    } else if (tabItem.isAppTab && tabItem.appBookmark != null) {
      final app = tabItem.appBookmark!;
      if (app.url != null && app.url!.isNotEmpty) {
        setState(() {
          _currentTab = BrowserTab.app;
          _currentApp = app;
          _currentWebViewUrl = app.url!;
          _currentCustomTabName = null; // Clear custom web tab name
          _selectedChatInboxId = null; // Clear selected chat inbox
          _error = null;
          if (_isEditMode) {
            _isEditMode = false;
          }
        });
        // Check bookmark status for the app
        _checkCurrentAppBookmarkStatus();
        _recordAppOpen(app);
        _updateProfileAnimationState();
      } else {
        setState(() {
          _error = context.l10n.browserAppNoUrl;
          _currentTab = BrowserTab.profile;
          _currentApp = null;
          _currentCustomTabName = null;
          _selectedChatInboxId = null;
        });
        _updateProfileAnimationState();
      }
    } else if (tabItem.isCustomTab && tabItem.record != null) {
      final record = tabItem.record!;
      final isRssTab = record.routerSubtype == RouterSubtype.channel;
      final tabName = record.metadata['name'] as String?;

      if (record.value.isNotEmpty) {
        setState(() {
          _currentTab = isRssTab ? BrowserTab.channel : BrowserTab.webview;
          _currentCustomTabName = isRssTab
              ? (tabName ?? context.l10n.browserTabChannel)
              : (tabName ?? context.l10n.browserTabWebTab);
          if (!isRssTab) {
            _selectedChatInboxId = null; // Clear selected chat inbox
            _currentWebViewUrl = record.value; // Set the URL for webview
          }
          _currentApp = null; // Clear current app
          _isCurrentAppBookmarked = false; // Clear bookmark state
          _isCurrentRssFeedInList = false; // Reset RSS feed list status
          _error = null;
          if (_isEditMode) {
            _isEditMode = false;
          }
        });
        // Check if RSS feed is in user's lists
        if (isRssTab) {
          _checkCurrentRssFeedInList();
        }
        _updateProfileAnimationState();
      } else {
        setState(() {
          _error = context.l10n.browserTabNoUrl;
          _currentTab = BrowserTab.profile;
          _currentCustomTabName = null;
          _currentApp = null;
          _isCurrentAppBookmarked = false; // Clear bookmark state
          _selectedChatInboxId = null; // Clear selected chat inbox
        });
        _updateProfileAnimationState();
      }
    }
  }

  Widget _buildWebViewWidget() {
    final urlToLoad =
        _currentWebViewUrl ?? widget.initialUrl ?? "https://google.com";

    return PublicOSWebView(
      key: ValueKey(urlToLoad), // Force rebuild when URL changes
      initialUrl: urlToLoad,
      // Passed so a mid-session permission change (the indicator's picker)
      // rebuilds this widget and the webview's didUpdateWidget re-evaluates the
      // running page's grants.
      grantsRevision: _grantsRevision,
      onError: (error) {
        setState(() {
          _error = error;
        });
      },
      onControllerCreated: (controller) {
        _webViewController = controller;
      },
      onCanGoBackChanged: (canGoBack) {
        if (canGoBack != _webViewCanGoBack) {
          setState(() => _webViewCanGoBack = canGoBack);
        }
      },
      // The connect event. true → the chip animates in; false → it hides.
      onConnectionChanged: (connected) {
        if (connected != _webConnected) {
          setState(() => _webConnected = connected);
        }
      },
      onActiveAccountChanged: (address) {
        if (address != _webActiveAccount) {
          setState(() => _webActiveAccount = address);
        }
      },
      // This page's chain registry + its chain. Both belong to the webview;
      // we hold them so the address-bar badge can render and switch.
      onChainRegistryCreated: (registry) => _webChains = registry,
      onChainChanged: (chainId) {
        if (chainId != _webChainId) setState(() => _webChainId = chainId);
      },
    );
  }

  /// The user picked another chain from the address-bar badge.
  ///
  /// Switching moves **this tab only** — `switchChain` writes the page's own
  /// registry, which decides what `eth_chainId` answers, which node reads are
  /// proxied to, and which chain a transaction is signed for under EIP-155.
  ///
  /// Then it **reloads the page**, and that is the part that makes the control
  /// useful rather than decorative. The switch already emits `chainChanged`,
  /// which is everything the spec asks and everything a modern dApp needs — but
  /// a dApp written before wallets could switch reads the chain once on mount
  /// and never listens, so without the reload the user switches and watches
  /// nothing happen. Those are exactly the sites this control exists for.
  Future<void> _switchWebChain(String chainId) async {
    final registry = _webChains;
    if (registry == null) return;
    try {
      registry.switchChain(chainId); // fires onChainChanged → badge re-renders
      await _webViewController?.reload();
    } catch (e) {
      // 4902 on a chain we do not carry. The picker only offers chains from
      // the registry, so this is a "cannot happen" that must still not crash.
      debugPrint('[web3] chain switch to $chainId refused: $e');
    }
  }

  Widget _buildManagementWidget() {
    return GroupVotingView(
      contact: _contact,
      isOrgMember: _isOrgMember,
      // Start below the overlapping address bar; scrolls up under it.
      topInset: _expandedVisualHeight,
      // Same hard chain-pull ProfilePage gets via onRefresh — lets the
      // management tab reload the org contact after a cast/start vote.
      // _syncFromChain self-guards on a null publicosAddress.
      onContactRefresh:
          _contact != null ? () => _syncFromChain(_contact!) : null,
    );
  }

  /// The channel tab on screen: the one in the profile's tab list, else the
  /// record the landing carried (Go to feed, a shared post's back step).
  ///
  /// The list is empty for a while on a profile this device had never loaded:
  /// the content shows as soon as a local stub of the contact exists, before
  /// the chain answers. Looking only in the list threw "RSS tab not found"
  /// there. Null = not known yet.
  Record? _currentChannelTab() {
    for (final tab in _profileTabs) {
      if (tab.routerSubtype == RouterSubtype.channel &&
          (tab.metadata['name'] as String?) == _currentCustomTabName) {
        return tab;
      }
    }
    final landed = _landingTabItem?.record;
    if (landed != null &&
        landed.routerSubtype == RouterSubtype.channel &&
        (landed.metadata['name'] as String?) == _currentCustomTabName) {
      return landed;
    }
    return null;
  }

  Widget _buildRssWidget() {
    final rssTab = _currentChannelTab();
    if (rssTab == null) {
      return const Center(
          child: PhigitalLoadingWidget(size: 28, showShadows: false));
    }

    // A roster of one — the door that gains the header: same channel, same
    // look as the feeds tab, because the header comes from the fetch result,
    // not from who asked.
    //
    // Channel tabs ride the same expanded-header collapse as the profile.
    // The inset is split on purpose: the OUTER padding is the collapsed
    // strip, so the viewport top — where the sort chips' PinnedHeaderSliver
    // sticks — sits just below the strip instead of hidden behind it; the
    // INNER topInset is the remaining expanded overhang, which is exactly
    // the scroll travel _syncHeaderToScroll maps to collapse progress, so the
    // list rises 1:1 with the shrinking header.
    return Padding(
      padding: EdgeInsets.only(top: _collapsedHeaderHeight),
      child: PostsList(
        feeds: [
          FeedSource(
            url: rssTab.value,
            title: _currentCustomTabName,
            foundAtContact: _contact,
            recordKey: rssTab.key,
          ),
        ],
        displayName: _currentCustomTabName,
        color: myColor,
        topInset: _expandedVisualHeight - _collapsedHeaderHeight,
        // The key on the address bar follows the row after every settled
        // load, and refetches when the menu changes the decision.
        refreshTick: _channelRefreshTick,
        onLoadingChanged: (loading) {
          if (!loading) _refreshSigninPref();
        },
      ),
    );
  }

  Color _getSelectedTabColor(ThemeData theme) {
    if (_currentTab == BrowserTab.chat) {
      return ThemeProvider.successLight;
    } else if (_currentCustomTabName != null && _currentTab == BrowserTab.channel) {
      return ThemeProvider.amberAccent;
    } else if (_currentCustomTabName != null &&
        _currentTab == BrowserTab.webview) {
      return ThemeProvider.infoLight;
    } else if (_currentApp != null && _currentTab == BrowserTab.app) {
      return ThemeProvider.errorLight; // Accent for app tabs
    }

    switch (_currentTab) {
      case BrowserTab.profile:
        return ThemeProvider.tealPrimary;
      case BrowserTab.chat:
        return ThemeProvider.successLight;
      case BrowserTab.settings:
        return ThemeProvider.slateLight;
      case BrowserTab.management:
        return ThemeProvider.tealPrimary;
      case BrowserTab.webview:
        return ThemeProvider.infoLight;
      case BrowserTab.channel:
        return ThemeProvider.amberAccent;
      case BrowserTab.app:
        return ThemeProvider.errorLight; // Accent for app tabs
    }
  }

  Color _getTextColor(Color backgroundColor) {
    final luminance = backgroundColor.computeLuminance();
    return luminance > 0.5 ? Colors.black87 : Colors.white;
  }

  /// The user switched the active XMTP key from inside the chat. Either the new
  /// key IS this chat's peer (self-chat → redirect to profile), or it rebinds
  /// the DM to (new key ↔ peer) — a different conversation — so rebuild to let
  /// the ValueKey(active inbox) on SimpleChatScreen remount it and reload.
  /// The no-key tile's action: the keychain, then the chat if an inbox was
  /// loaded there.
  Future<void> _loadKeysForChat() async {
    final before = PublicOS.clientXmtpInboxId;
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const KeychainSheet(),
    );
    if (!mounted || PublicOS.clientXmtpInboxId == before) return;
    await _onActiveKeyChanged();
  }

  Future<void> _onActiveKeyChanged() async {
    await _checkAndHandleSelfChatTab();
    if (mounted && _currentTab == BrowserTab.chat) {
      setState(() {});
    }
  }

  /// The hosted chat reports whether its conversation-settings sheet can be
  /// opened: a live opener once a topic resolves, null for a brand-new DM with
  /// no topic yet. Drives the address-bar gear (rendered only on the chat tab).
  /// Method tear-offs of the same chat state compare equal, so this dedupes the
  /// chat's redundant publishes; remount on key-switch hands over a fresh one.
  void _onChatSettingsAvailable(VoidCallback? opener) {
    if (!mounted || _chatSettingsOpener == opener) return;
    setState(() => _chatSettingsOpener = opener);
  }

  Future<void> _checkAndHandleSelfChatTab() async {
    final currentInboxId = PublicOS.clientXmtpInboxId;
    if (currentInboxId == null || currentInboxId.isEmpty) return;

    // If we're  currently on a chat tab that matches our own inbox ID
    if (_currentTab == BrowserTab.chat &&
        _selectedChatInboxId != null &&
        _selectedChatInboxId!.toLowerCase() == currentInboxId.toLowerCase()) {
      print('Browser: Detected self-chat tab, switching to profile');
      setState(() {
        _currentTab = BrowserTab.profile;
        _selectedChatInboxId = null;
      });

      // You can't DM yourself, so profile is the resting landing now: reseed it
      // so a back-press dismisses to the explorer instead of replaying the
      // (now-impossible) chat landing. Mirrors the landing-snapshot model.
      _landingTabItem = TabItem(browserTab: BrowserTab.profile, label: 'Profile');
      _hasNavigatedAway = false;

      _updateProfileAnimationState();
    }

    // Re-flag (the loaded key may have just changed under us).
    _reflagChatTabs();
  }

  /// Recompute the `isSelf` flag on every chat tab. The loaded inbox changes
  /// when the user switches keys mid-session, and the flag decides which entry
  /// the switcher dims - so it is recomputed rather than the entry removed.
  void _reflagChatTabs() {
    var changed = false;
    final reflagged = _chatTabs.map((chatTab) {
      final tabInboxId = chatTab['inboxId'] as String;
      final isSelf = _isLoadedInbox(tabInboxId);
      if ((chatTab['isSelf'] == true) != isSelf) changed = true;
      return {...chatTab, 'isSelf': isSelf};
    }).toList();

    if (changed) {
      setState(() {
        _chatTabs = reflagged;
      });
      _notifyTabDataChanged();
    }
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const PixelRainLoadingCorner(safeBottom: true);
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline,
              size: 64,
              color: ThemeProvider.errorLight,
            ),
            const SizedBox(height: 16),
            Text(
              context.l10n.browserErrorLoadingContent,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              _error!,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.browserBackToExplorer),
            ),
          ],
        ),
      );
    }

    switch (_currentTab) {
      case BrowserTab.profile:
        return ProfilePage(
          isEditMode: _isEditMode,
          contact: _contact,
          isOrgMember: _isOrgMember,
          // Start below the overlapping address bar; scrolls up under it.
          topInset: _expandedVisualHeight,
          onRefresh: _contact != null ? () => _syncFromChain(_contact!) : null,
          // Lets an NFT card's info dialog set this NFT as the viewer's avatar
          // (same self-write as the avatar dialog). Offered on any profile —
          // unlike the avatar dialog, a card is never already your pfp.
          onUseNftAsAvatar: _useNftAsAvatar,
        );
      case BrowserTab.chat:
        // For group chats, pass null as inboxId so SimpleChatScreen uses the
        // contact's conversation topic directly (no peer inbox ID for groups).
        // Pass `topic` defensively when this browser was opened with a topic
        // identifier (notification tap); SimpleChatScreen uses it as a fallback
        // when inboxId resolution didn't populate. No inbox loaded: the chat is
        // not built (it resolves a topic against the loaded inbox); a "load a
        // key" tile stands in and opens the keychain.
        return _contact != null && PublicOS.clientXmtpInboxId == null
            ? ChatNoKeyState(onLoadKeys: _loadKeysForChat)
            : _contact != null
            ? SimpleChatScreen(
                // Keyed on the active client inbox so switching XMTP keys
                // remounts the screen → fresh _initialize() re-resolves the
                // (new key ↔ peer) DM topic and reloads, instead of leaving the
                // previous key's conversation stalled on screen.
                key: ValueKey(
                    'chat:$_selectedChatInboxId:${PublicOS.clientXmtpInboxId}'),
                contact: _contact!,
                inboxId: _contact!.isGroupChat ? null : _selectedChatInboxId,
                topic: widget.identifierType ==
                        ContactIdentifierType.xmtpConversationTopic
                    ? widget.identifier
                    : null,
                // A live key switch either lands on this chat's own inbox
                // (self-chat → redirect to profile) or rebinds the DM to the new
                // key (→ remount + reload via the ValueKey above).
                onActiveKeyChanged: _onActiveKeyChanged,
                // Hands up an opener for the conversation-settings sheet once
                // the topic resolves; drives the address-bar gear.
                onChatSettingsAvailable: _onChatSettingsAvailable,
                // Deep-link ?message= pre-fill (e.g. Quests "claim <id>").
                messageDraft: widget.messageDraft,
              )
            : Center(child: Text(context.l10n.browserContactNotLoadedChat));
      case BrowserTab.management:
        return _buildManagementWidget();
      case BrowserTab.settings:
        return ContactSettingsScreen(
          contact: _contact,
        );
      case BrowserTab.webview:
        return _buildWebViewWidget();
      case BrowserTab.channel:
        return _buildRssWidget();
      case BrowserTab.app:
        // If we're waiting for a specific app to load (via the app/:key route), show loading
        if (widget.routeType == 'app' &&
            widget.routeKey != null &&
            _currentApp == null &&
            _error == null) {
          return PixelRainLoadingCorner(
            label: context.l10n.browserLoadingApp,
            safeBottom: true,
          );
        }
        // If there was an error finding the app, show error state
        if (_currentApp == null && _error != null) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline,
                    size: 48, color: ThemeProvider.warningLight),
                const SizedBox(height: 16),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () =>
                      setState(() => _currentTab = BrowserTab.profile),
                  child: Text(context.l10n.browserGoToProfile),
                ),
              ],
            ),
          );
        }
        return _buildWebViewWidget(); // App tabs use WebView too
      default:
        return Center(child: Text(context.l10n.browserUnknownTab(_currentTab.name)));
    }
  }

  void _showAddToListBottomSheet() async {
    // Get the current RSS tab info
    final rssTab = _currentChannelTab();
    if (rssTab == null) return;

    final result = await showAddToListsSheet(
      context,
      feedUrl: rssTab.value,
      feedTitle: rssTab.metadata['name'] as String?,
      feedDescription: null,
      feedFoundAtAccountAddress: _contact?.publicosAddress?.eip55With0x,
      // This is a CHANNEL, so anchor the follow on its record.key — the URL
      // is only where it lives today.
      feedRecordKey: rssTab.key,
    );

    // Refresh the RSS feed list status if something was added
    if (result == true) {
      _checkCurrentRssFeedInList();
    }
  }

  // ---------------------------------------------------------------------------
  // MATURE-CONTENT GATE. A profile whose owner set
  // `mature_content: true` ([Contact.isMatureContent]) is not shown until the
  // viewer says they are 18+. The yes is kept per profile in Core settings
  // (`mature_ok.<address>`, scoped to the signed-in session). The platform age
  // signals (Play Age Signals / Declared Age Range) come after launch.
  // ---------------------------------------------------------------------------

  /// The profile the viewer has cleared this visit (its address), or null.
  String? _matureCleared;

  /// The profile a gate check is running for, so build doesn't start two.
  String? _matureAskingFor;

  String? get _matureGateKey {
    final c = _contact;
    if (c == null || !c.isMatureContent) return null;
    return c.publicosAddress?.eip55With0x ?? widget.identifier;
  }

  void _scheduleMatureGate(String key) {
    if (_matureAskingFor == key) return;
    _matureAskingFor = key;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // iOS: mature profiles are not shown at all for now.
      // Apple 1.2 allows them only when the turn-on happens on a website;
      // until that website flow exists, iOS gets a "not on iPhone yet" note
      // and goes back. A stored yes from another platform is ignored here.
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        await _askMatureGate(iosBlocked: true);
        if (mounted) Navigator.of(context).maybePop();
        return;
      }
      final settingKey = 'mature_ok.$key';
      var ok = false;
      try {
        ok = (await PublicOSSettings.getSetting(settingKey))?.value == 'true';
      } catch (_) {} // signed out: ask every time
      if (!mounted) return;
      if (!ok) ok = await _askMatureGate() == true;
      if (!mounted) return;
      if (!ok) {
        Navigator.of(context).maybePop();
        return;
      }
      try {
        await PublicOSSettings.setSetting(
          settingKey,
          Record.asSettings(
            key: settingKey,
            value: 'true',
            isSystem: true,
          ),
        );
      } catch (_) {}
      if (mounted) setState(() => _matureCleared = key);
    });
  }

  Future<bool?> _askMatureGate({bool iosBlocked = false}) {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        constraints: const BoxConstraints(
            minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
        backgroundColor: tokens.surfaceDeep,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          l10n.matureGateTitle,
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            color: tokens.starkWhite,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          iosBlocked ? l10n.matureGateIosBody : l10n.matureGateBody,
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            color: tokens.textDim,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.matureGateBack,
              style: TextStyle(
                fontFamily: 'SpaceGrotesk',
                color: tokens.textDim,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (!iosBlocked) TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.matureGateContinue,
              style: TextStyle(
                fontFamily: 'SpaceGrotesk',
                color: tokens.starkWhite,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _scheduleDisplayedTabCatchUp();

    // Nothing of a mature profile paints until the viewer has answered.
    final matureKey = _matureGateKey;
    if (matureKey != null && _matureCleared != matureKey) {
      _scheduleMatureGate(matureKey);
      return Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor);
    }

    final profileBgUrl = _profileBackgroundUrl;
    final showBg = profileBgUrl != null && _currentTab == BrowserTab.profile;
    // Profile + management + channel show the expanded header and use the
    // scroll-driven collapse with the address bar overlapping the content.
    // Every other tab keeps the simple stacked Column (address bar above,
    // content below).
    final isExpandedView = _isExpandedHeaderTab;
    return PopScope(
      // Block the pop when a landing-replay is pending, OR (Android only) when
      // the embedded webview still has in-page history to step back through.
      // iOS gains nothing here — its edge-swipe stays native and the chevron
      // drives in-webview back.
      canPop: !_hasNavigatedAway && !_androidWebViewBack,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Tier 1: Android system-back steps back inside the webview.
        if (_androidWebViewBack) {
          await _webViewController?.goBack();
          return;
        }
        // Tier 2: replay the tab the Browser opened on.
        _handleTabSelection(_landingTabItem ?? _buildLandingTabItem());
        _hasNavigatedAway = false;
      },
      child: Scaffold(
        body: Stack(
          children: [
            // Layer 0: Full-screen background image (no gesture detectors).
            // Always holds its slot: an `if` here would shift every later
            // child on a tab switch, so the header would remount (and its
            // live canvas with it).
            Positioned.fill(
                child: showBg
                    ? _buildPageBackground(profileBgUrl)
                    : const SizedBox.shrink()),
            if (isExpandedView) ...[
              // Profile/management: content scrolls UNDER the address bar. It
              // carries a top inset (= expanded header) so it starts below the
              // bar, and its scroll drives the collapse via _syncHeaderToScroll.
              Positioned.fill(
                child: ContentMetricsListener(
                  onMetrics: _syncHeaderToScroll,
                  child: _buildContent(),
                ),
              ),
              // Address bar overlay. A transparent opaque-hit absorber behind it
              // catches touches over the see-through zone so they land on the
              // bar (and its buttons), not the scrolling content behind — you
              // scroll from the content area below. Only _buildAddressBar reads
              // _profileAnimation, so the per-frame rebuild is scoped here and
              // the scrolling content isn't rebuilt.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {},
                      ),
                    ),
                    AnimatedBuilder(
                      animation: _profileAnimation,
                      builder: (context, _) => _buildAddressBar(),
                    ),
                  ],
                ),
              ),
            ] else
              // Other tabs: unchanged Column (address bar above, content below).
              Column(
                children: [
                  AnimatedBuilder(
                    animation: _profileAnimation,
                    builder: (context, _) => _buildAddressBar(),
                  ),
                  Expanded(
                    child: _buildContent(),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// "Last visited apps" — record the open in Core's local history
  /// (`PublicOSAppRegistry.recordAppOpen`, settings-backed, per session). Fired
  /// at every site where an app tab becomes the CURRENT tab: the landing
  /// payload, the `/app/:appName` route resolution, and a tab-strip pick — so
  /// an app found on someone's profile counts exactly like one launched from
  /// the Apps tab. Fire-and-forget: history must never block a tab switch.
  /// No consumer on mobile yet — desktop's rail reads it.
  void _recordAppOpen(AppBookmark app) {
    PublicOSAppRegistry.recordAppOpen(app).catchError((_) => false);
  }

  // Check if the current app is bookmarked and update state
  Future<void> _checkCurrentAppBookmarkStatus() async {
    if (_currentApp == null) {
      setState(() {
        _isCurrentAppBookmarked = false;
      });
      return;
    }

    final isBookmarked = await PublicOSAppRegistry.isAppBookmarked(
      _currentApp!.appName,
      _currentApp!.ownerAccountAddress,
    );

    if (mounted) {
      setState(() {
        _isCurrentAppBookmarked = isBookmarked;
      });
    }
  }

  /// Is the current channel in ANY of the user's lists?
  ///
  /// A plain membership scan — no list outranks another, so there is nothing
  /// to special-case. Drives the single Follow (bookmark) affordance's
  /// filled/outline state.
  Future<void> _checkCurrentRssFeedInList() async {
    if (_currentTab != BrowserTab.channel || _currentCustomTabName == null) {
      setState(() => _isCurrentRssFeedInList = false);
      return;
    }

    try {
      final rssTab = _currentChannelTab();
      if (rssTab == null) throw StateError('RSS tab not found');

      final feedUrl = rssTab.value;
      if (feedUrl.isEmpty) {
        setState(() => _isCurrentRssFeedInList = false);
        return;
      }

      var inAnyList = false;
      for (final list in await PublicOSFeedLists.getUserLists()) {
        final feedsInList = await PublicOSFeedLists.getFeedsInList(list.id);
        if (feedsInList
            .any((f) => feedUrlKey(f.feedUrl) == feedUrlKey(feedUrl))) {
          inAnyList = true;
          break;
        }
      }

      if (mounted) setState(() => _isCurrentRssFeedInList = inAnyList);
    } catch (e) {
      print('Error checking RSS feed in list: $e');
      if (mounted) setState(() => _isCurrentRssFeedInList = false);
    }
  }

  /// Re-read whether the viewer follows the account on the profile tab. Cheap
  /// indexed lookup; called whenever the profile contact resolves and after a
  /// follow/unfollow. Self and address-less profiles are never "followed".
  Future<void> _refreshAccountFollowState() async {
    _refreshStarState();
    final addr = _contact?.publicosAddress?.eip55With0x;
    final session = PublicOS.sessionBlockchainAddress;
    if (addr == null || session == null || _selfProfile) {
      if (mounted && _isFollowingAccount) {
        setState(() => _isFollowingAccount = false);
      }
      return;
    }
    final following = await PublicOS.database
        .isFollowingAccount(session: session, account: addr);
    if (!mounted) return;
    setState(() => _isFollowingAccount = following);
  }

  /// Re-read the star of the account on the profile tab. Runs with the follow
  /// read, so it follows the same lifecycle.
  Future<void> _refreshStarState() async {
    final account = _contact?.publicosAddress;
    var starred = false;
    if (account != null && !_selfProfile) {
      try {
        starred = await PublicOSContacts.isStarred(account);
      } catch (_) {}
    }
    if (mounted && starred != _isStarred) setState(() => _isStarred = starred);
  }

  /// Star or un-star the account on the profile tab. A profile that is not a
  /// stored contact yet is saved by the same call.
  Future<void> _toggleStarCurrentAccount() async {
    final contact = _contact;
    if (contact?.publicosAddress == null || !_starShown) return;
    final next = !_isStarred;
    HapticFeedback.lightImpact();
    setState(() => _isStarred = next); // the button answers at once
    try {
      final now = await PublicOSContacts.setStarred(contact!, next);
      if (mounted && now != _isStarred) setState(() => _isStarred = now);
    } catch (_) {
      if (mounted) setState(() => _isStarred = !next);
    }
  }

  Future<void> _toggleFollowCurrentAccount() async {
    final account = _contact?.publicosAddress;
    final session = PublicOS.sessionBlockchainAddress;
    if (account == null || session == null || _selfProfile) return;
    if (_togglingAccountFollow) return; // re-entry guard (no spinner is shown now)
    final accountEip55 = account.eip55With0x;

    _togglingAccountFollow = true;
    try {
      // ONE affordance, one destination: the add-to-list sheet. It opens in
      // account mode, pre-checked with every list this account is already in,
      // so the same surface both follows and manages membership. There is no
      // separate follow-vs-manage path, and no magic list to toggle against.
      final changed = await showAddToListsSheet(
        context,
        accountAddress: accountEip55,
        feedTitle: _contact?.publicosDisplayName ?? _contact?.displayName,
      );

      // Dedupe only makes sense after an actual add. Sweep every list the
      // account now belongs to, so a channel isn't counted twice in any of
      // them.
      if (changed == true) {
        final listIds = await PublicOS.database
            .listsContainingAccount(session: session, account: accountEip55);
        for (final listId in listIds) {
          await _cleanupSingleFollowsForAccount(account, listId);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(localizedError(context.l10n, e))),
        );
      }
    }
    _togglingAccountFollow = false;
    if (!mounted) return;
    await _refreshAccountFollowState();
  }

  /// Reverse-cleanup: drop any Following-list single feeds whose URL
  /// matches one of [account]'s resolved profile channels. Matched by URL
  /// against A's derived set — NEVER by the nullable feedFoundAtAccountAddress.
  /// Only the Following list is swept; feeds the user filed in other lists are
  /// deliberate curation and left alone.
  /// After adding an ACCOUNT to [listId], drop that list's individual rows for
  /// the same channels — otherwise the channel is counted twice (once derived
  /// from the account, once as a stored row) and the post menu offers the wrong
  /// verb for it.
  ///
  /// Scoped to the list the account was just added to, never a list picked
  /// by name: no list is special.
  ///
  /// Matched on `record.key`, not URL: the stored row and the derived channel
  /// are the same channel even if the row's URL is stale. Rows without a key
  /// are raw-URL snapshots — deliberately NOT swept, since the user added that
  /// URL on purpose and it isn't claimed by the account follow.
  Future<void> _cleanupSingleFollowsForAccount(
    EthereumAddress account,
    int listId,
  ) async {
    try {
      final keys = (await PublicOSFollows.resolveProfileChannels(account))
          .map((c) => c.key)
          .toSet();
      if (keys.isEmpty) return;

      final owner = account.eip55With0x;
      for (final f in await PublicOSFeedLists.getFeedsInList(listId)) {
        final key = f.feedRecordKey;
        if (key == null || key.isEmpty) continue; // raw URL — leave it alone
        if (f.feedFoundAtAccountAddress != owner) continue; // another owner's
        if (keys.contains(key)) {
          await PublicOSFeedLists.removeFeedFromList(listId, f.id);
        }
      }
    } catch (e) {
      debugPrint('reverse-cleanup failed for ${account.eip55With0x}: $e');
    }
  }

  /// Anchors the profile "…" menu under its own button.
  final GlobalKey _profileMoreKey = GlobalKey();

  /// The profile overflow menu: QR · Copy profile link ·
  /// Flag (not on your own profile), in the action pills' frosted glass.
  void _openProfileMoreMenu() {
    final owner = _contact?.publicosAddress;
    final box = _profileMoreKey.currentContext?.findRenderObject() as RenderBox?;
    if (owner == null || box == null) return;
    // GlassContextMenu opens 12px below the point it is given; hand it the
    // button's bottom edge less 6 so the menu sits 6px under the pill.
    final anchor = box.localToGlobal(box.size.bottomCenter(Offset.zero)) -
        const Offset(0, 6);
    final l10n = context.l10n;
    GlassContextMenu.show(
      context,
      position: anchor,
      frosted: true,
      items: [
        // Edit, when the row had no room for it (see [_editInOverflow]).
        if (_editInOverflow)
          GlassContextMenuItem(
            icon: _isEditMode ? Icons.edit_off_rounded : Icons.edit_rounded,
            label:
                _isEditMode ? l10n.browserStopEditing : l10n.browserEditProfile,
            onTap: () => setState(() => _isEditMode = !_isEditMode),
          ),
        GlassContextMenuItem(
          icon: Icons.qr_code_2_rounded,
          label: l10n.desktopProfileQr,
          onTap: _openProfileQR,
        ),
        GlassContextMenuItem(
          icon: Icons.content_copy_rounded,
          label: l10n.desktopCopyProfileLink,
          onTap: _copyProfileLink,
        ),
        if (!_selfProfile)
          GlassContextMenuItem(
            icon: Icons.flag_outlined,
            label: l10n.flagAction,
            onTap: () => showFlagSheet(
              context,
              owner: owner,
              kind: FlagTargetKind.profile,
            ),
          ),
      ],
    );
  }

  void _copyProfileLink() {
    final address = _contact?.publicosAddress?.eip55With0x;
    if (address == null) return;
    final url = 'https://publicos.dev/publicosAddress/$address';
    Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.browserProfileLinkCopied)),
      );
    }
  }

  /// Pushes the full-screen profile QR page — same target as
  /// `select_account_screen._openProfileQR` for verified accounts.
  void _openProfileQR() {
    final contact = _contact;
    final address = contact?.publicosAddress?.eip55With0x;
    if (contact == null || address == null) return;
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => ProfileQrPage(
          address: address,
          contact: contact,
          displayName: contact.displayName,
        ),
      ),
    );
  }

  // Toggle bookmark status for current app
  Future<void> _toggleBookmarkCurrentApp() async {
    if (_currentApp == null) return;

    if (_isCurrentAppBookmarked) {
      // Remove bookmark
      final success = await PublicOSAppRegistry.removeBookmark(
        _currentApp!.appName,
        _currentApp!.ownerAccountAddress,
      );

      if (mounted) {
        final l10n = context.l10n;
        if (success) {
          setState(() {
            _isCurrentAppBookmarked = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content:
                    Text(l10n.browserRemovedApp(_currentApp!.displayName))),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.browserFailedRemoveBookmark)),
          );
        }
      }
    } else {
      // Add bookmark
      final success = await PublicOSAppRegistry.bookmarkApp(_currentApp!);

      if (mounted) {
        final l10n = context.l10n;
        if (success) {
          setState(() {
            _isCurrentAppBookmarked = true;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content:
                    Text(l10n.browserBookmarkedApp(_currentApp!.displayName))),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.browserFailedBookmarkApp)),
          );
        }
      }
    }
  }

  @override
  void dispose() {
    _live.remove(this);
    _animationController.dispose();
    _tabAnimationController.dispose();
    _marqueeAnimationController.dispose();
    _tabSwitchAnimationController.dispose();
    _stopMarqueeTimer();
    _displayedTabTimer?.cancel();
    _tabDataVersion.dispose();
    super.dispose();
  }
}

// Helper class for tab information
class _TabInfo {
  final BrowserTab tab;
  final String label;

  const _TabInfo({
    required this.tab,
    required this.label,
  });
}

// Helper class for tab bar items
class _TabBarItem {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final String? imageUrl;

  const _TabBarItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.imageUrl,
  });
}
