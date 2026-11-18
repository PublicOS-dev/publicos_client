import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:publicos_client/components/feeds/post_snap_physics.dart';
import 'package:publicos_client/components/glass_contact_icon.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/components/onboarding/onboarding_flow.dart';
import 'package:publicos_client/pages/account_center_page.dart';
import 'package:publicos_client/pages/app_settings_page.dart';
import 'package:publicos_client/pages/bsp_screen.dart';
import 'package:publicos_client/pages/explorer_views/apps_view.dart';
import 'package:publicos_client/pages/explorer_views/contacts_view.dart';
import 'package:publicos_client/pages/explorer_views/feeds_view.dart';
import 'package:publicos_client/pages/explorer_views/wallet_view.dart';
import 'package:publicos_client/pages/explorer_views/messages_view.dart';
import 'package:publicos_client/pages/node_page.dart';
import 'package:publicos_client/pages/notifications_screen.dart';
import 'package:publicos_client/pages/ssp_screen.dart';
import 'package:publicos_client/utils/notification_kinds.dart';
import 'package:publicos_client/utils/own_wallets.dart';
import 'package:publicos_client/pages/treasury_page.dart';
import 'package:publicos_client/pages/trust_tree_screen.dart';
import 'package:publicos_client/router.dart';
import 'package:publicos_client/router_helpers.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/widgets/shell_chrome_scope.dart';

/// Glass-themed 5-tab shell: Feeds / Contacts / Apps / Messages / Wallet.
///
/// Owns:
/// - AppBar (avatar + name + chain/SSP status icons)
/// - BottomNav (5 tabs)
/// - IndexedStack body (each tab always alive)
/// - Scroll-reactive chrome (AppBar + BottomNav hide on scroll down)
/// - Chain status polling
///
/// Onboarding gate — if the `onboarding_completed` setting isn't set, renders
/// `OnboardingFlow` (the doing-tour, `components/onboarding/`) in place of the
/// shell. Live mode: `_finish` writes the flag on the outro, then `onComplete`
/// swaps the shell in without a navigation.
class Explorer extends StatefulWidget {
  const Explorer({super.key});

  @override
  State<Explorer> createState() => _ExplorerState();
}

class _ExplorerState extends State<Explorer>
    with TickerProviderStateMixin, RouteAware, WidgetsBindingObserver {
  int _currentIndex = 0;
  bool? _needsOnboarding;

  // GlobalKey on the Feeds tab so we can call its public `refresh()` from
  // the shell after a route pop or a Feeds-tab-tap. Other tabs don't
  // currently need this hook; add a key when they do.
  final GlobalKey<RssFeedsViewState> _feedsKey =
      GlobalKey<RssFeedsViewState>();

  // Lazy tab cache: only the tabs the user has actually visited get built.
  // Once built, the widget instance is kept so state survives tab switching
  // (same behavior as before, just deferred).
  final List<Widget?> _tabCache = List.filled(5, null);

  // AppBar state — the self contact is read live from AppStateNotifier
  // (bound below); no local copy, so a self-edit propagates via the stream.
  String _rpcSource = 'public';
  bool _providerStatusLoaded = false;
  bool _chainReachable = false;
  bool _sspReachable = false;

  // Status polling. Each subsystem reschedules its own timer after every poll
  // so the cadence can track its current state: slow while healthy, fast while
  // down. Explorer owns the schedule (it's the always-alive shell); Core only
  // exposes the probes (PublicOS.pingRpc / PublicOS.pingSsp).
  Timer? _chainPollTimer;
  Timer? _sspPollTimer;
  // A probe can be mid-flight (up to 5s) when a resume kicks a fresh poll.
  // Without these, the two in-flight chains would each schedule a timer,
  // orphaning one and doubling the cadence.
  bool _chainPollInFlight = false;
  bool _sspPollInFlight = false;
  static const Duration _pollWhenUp = Duration(seconds: 60);
  static const Duration _pollWhenDown = Duration(seconds: 20);

  // upgradeRpcPostAuth() is expensive (a chain call + DB reads), so recovery
  // off the public fallback is throttled well below the poll cadence.
  static const Duration _rpcRecoveryInterval = Duration(minutes: 5);
  DateTime? _lastRpcRecoveryAttempt;

  // On-chain notifications: unread badge on the app-bar bell. TWO sweeps feed
  // it, on deliberately separate timers so neither cadence drags the other:
  //
  //   * contract events (vouch / citizenship / domain / profile) — slow. A
  //     profile edit is not time-critical.
  //   * wallet transfers (own Safes + walletEnabled keychain EOAs) — fast.
  //     "You got paid" should feel closer to a message than to a profile edit.
  //
  // COST: a wallet sweep is exactly TWO getLogs calls no matter how many
  // wallets are watched (getLogs ORs every address within one topic position —
  // see PublicOSWalletActivity), so 30s costs ~4 calls/min per user. That is
  // affordable for one client but NOT necessarily for the node once the user
  // count grows: the multiplier is per-user, and the node is a read-dominant
  // social DB. These two constants are the dial — raising _walletSweepInterval
  // to `Duration(minutes: 10)` is a one-literal change and needs no other edit.
  static const Duration _walletSweepInterval = Duration(seconds: 30);
  static const Duration _activitySweepInterval = Duration(minutes: 10);

  int _unreadCount = 0;
  Timer? _activityTimer;
  Timer? _walletTimer;
  // A sweep can still be in flight when the next tick fires (a cold-start
  // backfill walks many windows). Without this, ticks would stack and each
  // would re-scan the same range.
  bool _walletSweepInFlight = false;

  // Chrome visibility (AppBar + BottomNav slide together). The controller's
  // value is the SHOWN fraction, 1 = chrome in place, 0 = slid away. On the
  // hide side it is driven directly by consumed scroll (see
  // _onScrollNotification); the animation is used only for the reveal and
  // for finishing a half-hidden bar when a scroll ends.
  late final AnimationController _chromeCtrl;
  late final Animation<double> _chromeAnim;

  /// Reveal only: a downward pull of more than this in one frame brings the
  /// chrome back (pulling hard brings it in). The hide
  /// has no threshold — it follows the finger.
  static const double _scrollRevealThreshold = 6;

  // Back-to-exit guard. The explorer is the app root, so a system back here
  // pops straight out of the app. We intercept it (PopScope canPop:false) and
  // require a second back within `_exitWindow` to actually leave, surfacing a
  // centered pill in between so the exit is never accidental.
  bool _exitArmed = false;
  Timer? _exitArmTimer;
  static const Duration _exitWindow = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkOnboarding();
    _chromeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      value: 1.0,
    );
    _chromeAnim = CurvedAnimation(
      parent: _chromeCtrl,
      curve: Curves.easeOutCubic,
    );

    _loadMyContact();
    _ensurePublicosOnboarded();
    _loadProviderStatus();
    _startStatusPolling();
    _refreshUnreadCount(); // persisted badge immediately
    _sweepActivity(); // first activity poll on open
    _activityTimer = Timer.periodic(
      _activitySweepInterval,
      (_) => _sweepActivity(),
    );
    _startWalletSweep();
  }

  /// Start (or restart) the wallet-transfer sweep. Split out from initState so
  /// the lifecycle handler can stop it on pause and resume it on foreground —
  /// a backgrounded app must not keep hitting the node every 30s.
  void _startWalletSweep() {
    _walletTimer?.cancel();
    _sweepWallets(); // don't wait a full interval for the first pass
    _walletTimer = Timer.periodic(
      _walletSweepInterval,
      (_) => _sweepWallets(),
    );
  }

  void _stopWalletSweep() {
    _walletTimer?.cancel();
    _walletTimer = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appRouteObserver.unsubscribe(this);
    _stopStatusPolling();
    _stopWalletSweep();
    _activityTimer?.cancel();
    _exitArmTimer?.cancel();
    _chromeCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning to the foreground is always a clean slate. The exit pill must
    // never survive a background cycle — whatever backgrounded us (a confirmed
    // SystemNavigator.pop that only minimized, Home, app-switch), the pill is
    // cleared on resume so it can never get stuck on.
    if (state == AppLifecycleState.resumed) {
      _disarmExit();
      // Dart timers are suspended while backgrounded, so the dots are showing a
      // snapshot from whenever we were last foregrounded. Re-probe immediately
      // rather than waiting out the remainder of a stale schedule.
      _startStatusPolling();
      // Same reasoning for the wallet sweep, plus a cost one: at a 30s cadence
      // a backgrounded app left ticking would be pure waste against the node.
      // (The 15-min Workmanager worker owns the app-closed case.)
      _startWalletSweep();
    } else if (state == AppLifecycleState.paused) {
      _stopStatusPolling();
      _stopWalletSweep();
    }
  }

  /// Fired when a route pushed above this one (browser, post detail, etc.)
  /// pops back. Refresh the visible tab so data mutated inside the pushed
  /// route shows up — but silently (no spinner) so the user doesn't see a
  /// loading flash on every back gesture.
  @override
  void didPopNext() {
    if (_currentIndex == 0) {
      _feedsKey.currentState?.refresh(silent: true);
    }
  }

  Future<void> _checkOnboarding() async {
    try {
      final record = await PublicOSSettings.getSetting('onboarding_completed');
      if (mounted) {
        setState(() => _needsOnboarding = record?.value != 'true');
      }
    } catch (_) {
      if (mounted) setState(() => _needsOnboarding = true);
    }
  }

  // Per-account flag marking that the one-time PublicOS onboarding (upsert the
  // org contact + follow its newsletter) has run. Scoped by PublicOSSettings'
  // (key, sessionAddress) keying, so every account does it once.
  static const String _publicosOnboardedFlag = 'publicos_onboarded';

  // The org is resolved by display NAME, never a hardcoded address, so this
  // survives an org redeploy to a different account address.
  static const String _publicosOrgName = 'PublicOS';

  // Onboarding follows the ACCOUNT, so there is no per-channel key to know:
  // whatever the org publishes resolves at read time, including channels that
  // did not exist at onboarding.

  /// One-time, name-resolved onboarding of the canonical PublicOS org: upsert
  /// the "PublicOS" contact and follow its newsletter RSS tab as a single
  /// list, so a brand-new user lands in the feeds already following PublicOS
  /// (rendered "via PublicOS", as if followed from the profile).
  ///
  /// Deploy-agnostic: `resolveByIdentifier` does an on-chain display-name
  /// lookup (AccountMemory, resolved from ModuleRegistry at runtime), so no
  /// address is baked in. The flag is set ONLY after a successful resolve, so
  /// a first boot with no chain connectivity simply retries next launch.
  /// Best-effort — never blocks Explorer.
  Future<void> _ensurePublicosOnboarded() async {
    var changed = false;
    for (final (name, flag) in _defaultFollows) {
      changed = await _ensureDefaultFollow(name, flag) || changed;
    }
    // Surface the freshly-seeded follows without a manual refresh — covers
    // the no-onboarding-overlay path where Feeds is already built on landing.
    if (changed && mounted && _currentIndex == 0) {
      _feedsKey.currentState?.refresh(silent: true);
    }
  }

  /// The accounts every new account follows into the default list, each with
  /// its OWN one-time flag. A separate flag per account means an account that
  /// already finished onboarding still picks up a newly added default on next
  /// launch.
  static const List<(String, String)> _defaultFollows = [
    (_publicosOrgName, _publicosOnboardedFlag),
    ('jmsl', 'jmsl_default_follow'),
    // TheOrg lists the channels its members run (Diez Palomas, Backstage).
    ('TheOrg', 'theorg_default_follow'),
  ];

  /// Resolve [name] on chain, upsert the contact, follow the ACCOUNT into the
  /// default list, then burn [flag]. Returns true when it followed now.
  Future<bool> _ensureDefaultFollow(String name, String flag) async {
    try {
      final already = await PublicOSSettings.getSetting(flag);
      if (already?.value == 'true') return false;

      // Resolve by name → on-chain → fetchContact (returns the fully-enriched
      // contact incl. records). Null when offline / not found: bail WITHOUT
      // setting the flag so the next boot retries.
      final org = await PublicOSContacts.resolveByIdentifier(name);
      if (org == null || org.publicosAddress == null) return false;

      // Upsert the contact.
      await PublicOSContacts.saveContact(org);

      // NO channel-record gate. Onboarding seeds the ACCOUNT (below), so the
      // org's channel records are nothing to it: `resolveProfileChannels` reads
      // the org's channel set live every time the list is opened. Gating on
      // them would only create a failure mode — a momentarily thin profile
      // blocking an onboarding that would have worked fine, and whose channels
      // would have appeared on first read anyway.
      final following = await _ensureDefaultList();
      final session = PublicOS.sessionBlockchainAddress;
      if (following == null || session == null) return false;

      // Seed the ACCOUNT, not its channels. The merge resolver derives the
      // org's channels from its profile at read time, so a brand-new user
      // lands following everything PublicOS publishes — and keeps following
      // whatever it publishes NEXT, without another onboarding pass. Under the
      // old model we stored two channel snapshots that never learned about a
      // third.
      await PublicOS.database.followAccount(
        session: session,
        account: org.publicosAddress!.eip55With0x,
        listId: following.id,
      );

      // Mark done only after a successful resolve + save.
      await PublicOSSettings.setSetting(
        flag,
        Record.asSettings(
          key: flag,
          value: 'true',
          isSystem: true,
          isExpired: false,
        ),
      );
      return true;
    } catch (_) {
      // Best-effort — never block Explorer.
      return false;
    }
  }

  /// Get-or-create the DEFAULT list (idempotent). Name/icon mirror
  /// feeds_view.dart's `_defaultListName`/`_defaultListIcon` — the canonical
  /// owner of the convention. Nothing about this list is special; the name is
  /// a bootstrap default the user is free to rename or delete.
  static Future<FeedList?> _ensureDefaultList() async {
    const followingName = 'Following';
    const followingIcon = '👾';
    final lists = await PublicOSFeedLists.getUserLists();
    for (final l in lists) {
      if (l.name == followingName) return l;
    }
    return PublicOSFeedLists.createList(followingName, icon: followingIcon);
  }

  Future<void> _loadMyContact() async {
    // Seed the global self snapshot once if it isn't loaded yet. The app-bar
    // icon/name bind to AppStateNotifier (see _buildAppBar) and repaint live
    // from the self-contact stream — no local copy to keep in sync.
    if (AppStateNotifier.currentMyContact == null) {
      await AppStateNotifier.loadMyContact();
    }
    _freshenMyContact();
  }

  /// The account this process has already re-read from chain, so landing on
  /// the explorer again (a rebuild, a pop back) does not refetch — but a
  /// switch to another account does.
  static String? _freshenedFor;

  /// Re-read the user's own contact from CHAIN once per boot, membership
  /// included.
  ///
  /// The local row is what everything paints, and its `isCitizen` is durable:
  /// `fetchContact` never re-reads it unless forced. So someone vouched since
  /// their last session would keep the ghost avatar app-wide until they
  /// happened to open their own profile. This is that profile visit, done at
  /// landing:
  /// `fetchContact(self, forceMembership: true)` saves the row and emits on
  /// `selfContactUpdates`, and the app bar, wallet and every other self
  /// surface repaint from the stream. Background, best-effort: the cached
  /// contact is already on screen, and a failed read leaves it there.
  Future<void> _freshenMyContact() async {
    final hex = PublicOS.myPublicosAddress;
    if (hex == null || _freshenedFor == hex.toLowerCase()) return;
    _freshenedFor = hex.toLowerCase();
    try {
      await PublicOSContacts.fetchContact(
        EthereumAddress.fromHex(hex),
        forceMembership: true,
      );
    } catch (e) {
      _freshenedFor = null; // let the next landing try again
      Log.e('Explorer', 'Self contact refresh failed: $e');
    }
  }

  Future<void> _loadProviderStatus() async {
    if (!mounted) return;
    setState(() {
      _rpcSource = PublicOS.activeRpcSource;
      _providerStatusLoaded = true;
    });
  }

  // ---------------------------------------------------------------------------
  // Status polling (BSP + SSP)
  //
  // Kick both subsystems immediately, then let each reschedule itself. Healthy
  // subsystems poll every 60s; downed ones retry every 20s so recovery shows up
  // fast without hammering a live endpoint.
  // ---------------------------------------------------------------------------

  void _startStatusPolling() {
    _pollChainStatus();
    _pollSspStatus();
  }

  void _stopStatusPolling() {
    _chainPollTimer?.cancel();
    _chainPollTimer = null;
    _sspPollTimer?.cancel();
    _sspPollTimer = null;
  }

  Future<void> _pollChainStatus() async {
    if (_chainPollInFlight) return;
    _chainPollInFlight = true;
    _chainPollTimer?.cancel();

    try {
      // PublicOS.pingRpc() probes the *active* endpoint and never fails over.
      // Do NOT use PublicOSBsp.getBlockNumber() here: on a single timeout it
      // calls connectToAvailableRPC(), which permanently repoints the whole
      // app's web3Client at the public node.
      final reachable = await PublicOS.pingRpc();
      if (!mounted) return;

      final source = PublicOS.activeRpcSource;
      Log.i('Explorer',
          '[status] bsp reachable=$reachable source=$source url=${PublicOS.activeRpcUrl}');

      if (_chainReachable != reachable || _rpcSource != source) {
        setState(() {
          _chainReachable = reachable;
          _rpcSource = source;
        });
      }

      // Amber (public fallback) must not be a one-way door.
      if (reachable && source == 'public') await _maybeRecoverRpc();

      if (!mounted) return;
      _chainPollTimer = Timer(
        _chainReachable ? _pollWhenUp : _pollWhenDown,
        _pollChainStatus,
      );
    } finally {
      _chainPollInFlight = false;
    }
  }

  Future<void> _pollSspStatus() async {
    if (_sspPollInFlight) return;
    _sspPollInFlight = true;
    _sspPollTimer?.cancel();

    try {
      // pingSsp() re-resolves nothing — initSSP() would hit the chain and the DB.
      final reachable = await PublicOS.pingSsp();
      if (!mounted) return;

      Log.i('Explorer',
          '[status] ssp reachable=$reachable source=${PublicOS.activeSspSource} '
          'url=${PublicOS.activeSspUrl}');

      if (_sspReachable != reachable) setState(() => _sspReachable = reachable);

      _sspPollTimer = Timer(
        reachable ? _pollWhenUp : _pollWhenDown,
        _pollSspStatus,
      );
    } finally {
      _sspPollInFlight = false;
    }
  }

  /// Try to climb back off the public RPC onto the user's BSP/custom endpoint.
  /// Throttled to [_rpcRecoveryInterval] because upgradeRpcPostAuth() costs a
  /// chain call plus DB reads, and only attempted for a signed-in account.
  Future<void> _maybeRecoverRpc() async {
    if (PublicOS.sessionBlockchainAddress == null) return;

    final last = _lastRpcRecoveryAttempt;
    if (last != null &&
        DateTime.now().difference(last) < _rpcRecoveryInterval) {
      return;
    }
    _lastRpcRecoveryAttempt = DateTime.now();

    try {
      await PublicOS.upgradeRpcPostAuth();
    } catch (e) {
      Log.w('Explorer', '[status] rpc recovery failed: $e');
      return;
    }
    if (!mounted) return;

    final source = PublicOS.activeRpcSource;
    if (source != _rpcSource) {
      Log.i('Explorer', '[status] rpc recovered: $_rpcSource -> $source');
      setState(() => _rpcSource = source);
    }
  }

  /// Read the persisted activity into the bell badge (no network). Counts
  /// through the same filter + 24h throttle + per-type toggles the
  /// notifications screen uses (notification_kinds.dart), so the badge never
  /// disagrees with the list.
  Future<void> _refreshUnreadCount() async {
    try {
      final raw = await PublicOSActivity.getStored(limit: 200);
      final enabled = await loadEnabledNotifKinds();
      final n = unreadNotifCount(buildNotifications(raw, enabled));
      // One-line health check for the whole pipeline: how many rows are
      // stored, how many kinds are enabled, what the badge will show. Reading
      // it answers "is the sweep finding nothing, or is the filter eating it".
      debugPrint(
          '[activity] stored=${raw.length} enabledKinds=${enabled.length} unread=$n');
      if (!mounted || n == _unreadCount) return;
      setState(() => _unreadCount = n);
    } catch (e) {
      debugPrint('[activity] badge read FAILED: $e');
    }
  }

  /// Poll P1 contract events into the activity cache, then refresh the badge
  /// through the shared filter/throttle pipeline.
  Future<void> _sweepActivity() async {
    try {
      await PublicOSActivity.sweep(); // persist new events
      await _refreshUnreadCount();
    } catch (e, st) {
      // A silent catch on a background poll is how a feature dies quietly on
      // one platform while looking fine on the other: the bell shows nothing
      // and the reason is swallowed on every tick.
      debugPrint('[activity] contract sweep FAILED: $e');
      debugPrint('$st');
    }
  }

  /// Poll token transfers touching the user's OWN wallets (personal main Safe +
  /// every org main Safe + `walletEnabled` keychain EOAs) into the same
  /// activity cache, then refresh the badge.
  ///
  /// The watched set is enumerated CLIENT-side (`loadOwnReceivingWallets`) and
  /// handed to Core: "which wallets do I show" is a UI policy — `walletEnabled`
  /// is literally the Wallet-tab toggle — so Core takes the addresses as a
  /// parameter rather than deriving them.
  Future<void> _sweepWallets() async {
    if (_walletSweepInFlight) return; // a cold-start backfill can outrun a tick
    _walletSweepInFlight = true;
    try {
      final me = PublicOS.myPublicosAddress;
      if (me == null) return;
      final scan = await scanOwnReceivingWallets(EthereumAddress.fromHex(me));

      // **Do not sweep on a partial watched set.** Sweeping is what advances
      // the cursor, and the cursor is a promise that the range was handled. If
      // a source failed we do not know what to look for, so scanning would
      // step past those blocks having matched the wrong wallets — and Core is
      // right never to re-scan them.
      //
      // Cost of skipping: nothing. The next tick retries with the cursor
      // untouched. Cost of NOT skipping: a transfer to the main Safe gets
      // swept past by a run whose Safe lookup failed, and becomes permanently
      // invisible.
      if (!scan.complete) {
        debugPrint('[activity] wallet scan incomplete — skipping sweep so the '
            'cursor does not advance past unwatched blocks');
        return;
      }
      final wallets = scan.wallets;
      if (wallets.isEmpty) return;
      await PublicOSWalletActivity.sweep(
        wallets: wallets
            .map((w) => EthereumAddress.fromHex(w.address))
            .toList(growable: false),
      );
      await _refreshUnreadCount();
    } catch (e, st) {
      // Best-effort, exactly like _sweepActivity: a failed pass leaves the
      // cursor untouched (Core guarantees that), so the next tick retries it.
      // Logged, not swallowed — see _sweepActivity.
      debugPrint('[activity] wallet sweep FAILED: $e');
      debugPrint('$st');
    } finally {
      _walletSweepInFlight = false;
    }
  }

  Future<void> _refreshAfterBspPop() async {
    try {
      await PublicOS.upgradeRpcPostAuth();
    } catch (_) {}
    if (!mounted) return;
    await _pollChainStatus();
  }

  Future<void> _refreshAfterSspPop() async {
    // The user may have picked a different SSP, so re-resolve (initSSP) rather
    // than just ping, then let the poller pick up the new endpoint's state.
    try {
      await PublicOS.initSSP();
    } catch (e) {
      Log.w('Explorer', '[status] initSSP after SSP screen failed: $e');
    }
    if (!mounted) return;
    await _pollSspStatus();
  }

  // ---------------------------------------------------------------------------
  // Chrome hide/show on scroll
  // ---------------------------------------------------------------------------

  // Quick-return chrome: the header moves pixel by pixel with the finger.
  //
  // THE RULE: the finger moves the chrome, nothing else. Every scroll update
  // that carries drag details hands its delta to the bar, in BOTH directions,
  // up to what is left of the bar's height: the body padding changes by that
  // amount (the bar, the tab's fixed header rows and the list all move
  // together) and the list's own scroll offset is corrected by the same
  // amount, so the posts hold still under the moving header instead of
  // travelling at twice the finger's speed. That correction is the whole
  // trick: it is what a nested scroll view does when a SliverAppBar consumes
  // the scroll first, done with one position write. forcePixels notifies the
  // viewport but dispatches no ScrollNotification, so there is no feedback
  // loop.
  //
  // Flings, the feed's snap spring, its settling ticks and the edge bounce
  // carry no drag details and never touch the chrome. Reading them (a
  // per-frame velocity gate tied to the refresh rate, or the spring's ticks)
  // makes the bars a coin toss after a swipe back, and a snap's last
  // millimetre could flip them.
  //
  // FINISH: when the finger lets go with the bar part-way, it animates to the
  // nearer end. The let-go is the first
  // update without drag details, or the scroll's end.
  //
  // TOP: a scroll that ends at the top shows the chrome.
  //
  // SECOND SWIPE: with the bars fully hidden, the first downward drag
  // only scrolls; the next one reveals, 1:1. An upward drag starts
  // the count again. A drag that starts with the bars part-way or shown is
  // never gated, and the top rule is unchanged.

  /// Downward drags finished since the last upward one.
  int _downSwipes = 0;

  /// Net scroll delta of the drag in progress (negative = finger moved down).
  double _dragNet = 0;
  bool _dragOpen = false;

  /// Whether the drag in progress may reveal the bars.
  bool _dragMayReveal = true;

  /// A drag shorter than this (px, net) counts in neither direction.
  static const double _swipeCountSlop = 8;

  void _closeDrag() {
    if (!_dragOpen) return;
    _dragOpen = false;
    if (_dragNet <= -_swipeCountSlop) {
      _downSwipes++;
    } else if (_dragNet >= _swipeCountSlop) {
      _downSwipes = 0;
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;
    if (notification is ScrollStartNotification) {
      if (notification.dragDetails != null) {
        _closeDrag();
        _dragOpen = true;
        _dragNet = 0;
        _dragMayReveal = _chromeCtrl.value > 0.0 || _downSwipes >= 1;
      }
    } else if (notification is ScrollUpdateNotification) {
      if (notification.dragDetails == null) {
        // Not the finger (a fling, a snap, a bounce): only the let-go counts.
        _closeDrag();
        _finishChrome();
      } else {
        final delta = notification.scrollDelta ?? 0;
        _dragNet += delta;
        if (delta < 0 && !_dragMayReveal) return false;
        _consumeIntoChrome(notification, delta);
      }
    } else if (notification is ScrollEndNotification) {
      _closeDrag();
      if (metrics.pixels <= 0) {
        _setChromeVisible(true);
      } else {
        _finishChrome();
      }
    }
    return false;
  }

  /// Hand [delta] px of the finger's scroll to the chrome: upward scroll
  /// (positive delta) hides, downward reveals, each up to what is left of the
  /// bar, and the list's offset is corrected by the consumed amount so the
  /// content stays attached to the finger while the bar moves.
  void _consumeIntoChrome(ScrollUpdateNotification n, double delta) {
    // In overscroll (pull-to-refresh settling) the offset is not ours to
    // correct; leave the bar alone, the top rule will show it.
    if (delta == 0 || n.metrics.outOfRange) return;
    final shown = _chromeCtrl.value;
    final double consumed = delta > 0
        ? math.min(delta, shown * kToolbarHeight)
        : -math.min(-delta, (1 - shown) * kToolbarHeight);
    if (consumed == 0) return;
    final ctx = n.context;
    if (ctx == null) return;
    final position = Scrollable.maybeOf(ctx)?.position;
    if (position == null) return;
    final corrected = position.pixels - consumed;
    if (corrected < position.minScrollExtent ||
        corrected > position.maxScrollExtent) {
      return;
    }
    // Setting value stops any running finish animation, which is what we
    // want: the finger has taken over.
    _chromeCtrl.value = shown - consumed / kToolbarHeight;
    // forcePixels is @protected (meant for ScrollPosition subclasses), but it
    // is the only write that moves the offset WITHOUT ending the drag
    // (jumpTo calls goIdle, which kills the active drag) and without
    // dispatching notifications (which would re-enter this handler).
    // NestedScrollView does the same from the inside; we do it from here.
    // ignore: invalid_use_of_protected_member
    position.forcePixels(corrected);
  }

  /// A scroll ended with the bar part-way: finish to the nearer end.
  void _finishChrome() {
    final v = _chromeCtrl.value;
    if (v <= 0.0 || v >= 1.0 || _chromeCtrl.isAnimating) return;
    if (v >= 0.5) {
      _chromeCtrl.forward();
    } else {
      _chromeCtrl.reverse();
    }
  }

  void _setChromeVisible(bool visible) {
    if (visible && _chromeCtrl.value < 1.0) {
      _chromeCtrl.forward();
    } else if (!visible && _chromeCtrl.value > 0.0) {
      _chromeCtrl.reverse();
    }
  }

  // ---------------------------------------------------------------------------
  // Apps-tab system-app routing
  // ---------------------------------------------------------------------------

  // AppsView (launcher) calls this when the user taps a system-app tile.
  // Four of the old "system apps" (feeds/accounts/messaging/wallets) are
  // now bottom-nav tabs, so those just switch tab. The rest push a glass
  // CupertinoPageRoute so the horizontal-slide transition + iOS swipe-back
  // gesture match the rest of the app.
  //
  // The tile cleanup inside AppsView itself (so feeds/accounts/etc no
  // longer appear as system apps) is a Phase 3C change — for now the
  // tiles still exist and route here.
  void _openSystemApp(String appId) {
    switch (appId) {
      case 'feeds':
        setState(() => _currentIndex = 0);
        return;
      case 'accounts':
        setState(() => _currentIndex = 1);
        return;
      case 'messaging':
        setState(() => _currentIndex = 3);
        return;
      case 'wallets':
        setState(() => _currentIndex = 4);
        return;
      case 'social_graph':
        final addr = AppStateNotifier.currentMyContact?.publicosAddress;
        if (addr == null) return;
        Navigator.of(context).push(
          CupertinoPageRoute(
            builder: (_) => TrustTreeScreen(initialAddress: addr),
          ),
        );
        return;
    }

    final screen = _buildSystemAppScreen(appId);
    if (screen == null) return;
    Navigator.of(context).push(
      CupertinoPageRoute(builder: (_) => screen),
    );
  }

  Widget? _buildSystemAppScreen(String appId) {
    switch (appId) {
      case 'treasury':
        return const TreasuryPage();
      case 'account':
        return const AccountCenterPage();
      case 'settings':
        return const AppSettingsPage();
      case 'bsp':
        return const BspScreen();
      case 'ssp':
        return const SspScreen();
      case 'nodes':
        return const NodePage();
      default:
        return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Provider icon colors
  // ---------------------------------------------------------------------------

  /// Chain dot. Grey = unreachable. Amber = reachable, but we've fallen back to
  /// the public node rather than the user's own BSP. Green = reachable on the
  /// endpoint the user chose or is enlisted with.
  Color _chainIconColor(BuildContext context) {
    final tokens = GlassTokens.of(context);
    if (!_chainReachable) return tokens.textDim;
    if (_rpcSource == 'public') return tokens.fallbackAccent;
    return tokens.connectedAccent;
  }

  /// SSP dot. Green = connected, grey = not. Deliberately two-state: "fallback"
  /// is a coherent idea for an RPC (a public node still serves you) but not for
  /// social content — either an SSP gives you space or it doesn't. Core still
  /// carries a 'default' source; the UI just refuses to dignify it as a tier.
  Color _sspIconColor(BuildContext context) {
    final tokens = GlassTokens.of(context);
    if (!_providerStatusLoaded) return tokens.textDim;
    return _sspReachable ? tokens.connectedAccent : tokens.textDim;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_needsOnboarding == true) {
      return OnboardingFlow(
        onComplete: () {
          if (mounted) setState(() => _needsOnboarding = false);
        },
      );
    }

    final tokens = GlassTokens.of(context);
    final mediaPadding = MediaQuery.of(context).padding;
    // EXPERIMENT: icons-only bar, shorter than Material's 56. Restore the
    // commented line (and the ones in _buildBottomNav) to go back.
    // const bottomNavHeight = kBottomNavigationBarHeight;
    const bottomNavHeight = _kExperimentNavHeight;
    final placeholderColor = tokens.starkWhite;

    return PopScope(
      // Never let the framework pop the root route on its own — we arm the
      // exit ourselves so the first back only shows the pill.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleRootBack();
      },
      child: Scaffold(
      backgroundColor: tokens.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              // Body padding tracks chrome visibility so content expands
              // into the freed space when AppBar/BottomNav slide out. The
              // animation only runs during the 220ms slide, not on every
              // scroll tick, so the relayout cost is bounded.
              child: AnimatedBuilder(
                animation: _chromeAnim,
                builder: (context, child) {
                  final v = _chromeAnim.value;
                  return Padding(
                    padding: EdgeInsets.only(
                      top: mediaPadding.top + kToolbarHeight * v,
                      bottom: mediaPadding.bottom + bottomNavHeight * v,
                    ),
                    child: child,
                  );
                },
                // The tabs read the same animation to move their own
                // floating buttons with the nav (ShellChromeFollower).
                child: ShellChromeScope(
                  shown: _chromeAnim,
                  bottomInset: mediaPadding.bottom,
                  child: IndexedStack(
                  index: _currentIndex,
                  children: List.generate(5, (i) {
                    if (i == _currentIndex || _tabCache[i] != null) {
                      _tabCache[i] ??= _buildTabFor(i, placeholderColor);
                      // A hidden tab is offstage for real: its tickers stop
                      // and its inline video tiles read TickerMode.of and
                      // release their player.
                      // IndexedStack alone keeps hidden children fully
                      // live (Visibility.maintain), which would let a
                      // feed clip play on under another tab.
                      return TickerMode(
                        enabled: i == _currentIndex,
                        child: _tabCache[i]!,
                      );
                    }
                    return const SizedBox.shrink();
                  }),
                  ),
                ),
              ),
            ),
          ),

          // AppBar — kToolbarHeight only, pinned below OS status bar.
          Positioned(
            top: mediaPadding.top,
            left: 0,
            right: 0,
            height: kToolbarHeight,
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _chromeAnim,
                builder: (context, child) {
                  return Transform.translate(
                    offset: Offset(
                      0,
                      -kToolbarHeight * (1 - _chromeAnim.value),
                    ),
                    child: Opacity(
                      opacity: _chromeAnim.value,
                      child: child,
                    ),
                  );
                },
                child: _buildAppBar(context, tokens),
              ),
            ),
          ),

          // BottomNav — slides down off-screen when chrome hidden
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _chromeAnim,
                builder: (context, child) {
                  final slideHeight = bottomNavHeight + mediaPadding.bottom;
                  return Transform.translate(
                    offset: Offset(0, slideHeight * (1 - _chromeAnim.value)),
                    child: Opacity(
                      opacity: _chromeAnim.value,
                      child: child,
                    ),
                  );
                },
                child: _buildBottomNav(context, tokens),
              ),
            ),
          ),

          // Back-to-exit pill — centered, fades in for `_exitWindow` after the
          // first system-back on the app root (see _handleRootBack). Purely
          // informational, so it never intercepts touches.
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: AnimatedScale(
                  scale: _exitArmed ? 1.0 : 0.92,
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutBack,
                  child: AnimatedOpacity(
                    opacity: _exitArmed ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 160),
                    child: _buildExitPill(tokens),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Back-to-exit guard
  // ---------------------------------------------------------------------------

  // First back arms the exit + shows the pill; a second back within
  // `_exitWindow` confirms and leaves. The pill must never outlive a foreground
  // session: the timer auto-dismisses it while we stay in front, and
  // `didChangeAppLifecycleState` clears it on resume in case the OS only
  // backgrounded us instead of killing the app (Android's SystemNavigator.pop
  // is not reliably terminal).
  void _handleRootBack() {
    if (_exitArmed) {
      // Dismiss FIRST, then ask to leave — if we're only backgrounded, we
      // return to a clean slate instead of a stuck pill.
      _disarmExit();
      SystemNavigator.pop();
      return;
    }
    _armExit();
  }

  void _armExit() {
    _exitArmTimer?.cancel();
    setState(() => _exitArmed = true);
    // The timer is the in-foreground guarantee: no second back → pill clears
    // itself after the window, so a stray back press can't leave it half-armed.
    _exitArmTimer = Timer(_exitWindow, _disarmExit);
  }

  void _disarmExit() {
    _exitArmTimer?.cancel();
    _exitArmTimer = null;
    if (mounted && _exitArmed) setState(() => _exitArmed = false);
  }

  Widget _buildExitPill(GlassTokens tokens) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        // Borderless: there is no ring, so the fill has to
        // carry the edge on its own — one tone step above `surfaceElevated`,
        // opaque so the scaffold can't mute it back down.
        color: Color.alphaBlend(tokens.glassFillHover, tokens.surfaceElevated),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: tokens.glassShadow,
            offset: const Offset(0, 4),
            blurRadius: 16,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.arrow_back_rounded, size: 16, color: tokens.textDim),
          const SizedBox(width: 8),
          Text(
            context.l10n.explorerBackAgainToExit,
            style: TextStyle(
              color: tokens.starkWhite,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  // Lazy tab constructor. Each tab is built the first time its index is
  // shown; the cache (`_tabCache`) keeps the instance alive across switches
  // so state (scroll offset, in-flight loads, etc) is preserved exactly
  // like the original eager IndexedStack.
  Widget _buildTabFor(int index, Color placeholderColor) {
    switch (index) {
      case 0:
        return RssFeedsView(
          key: _feedsKey,
          color: placeholderColor,
          searchQuery: '',
        );
      case 1:
        return const ContactsView();
      case 2:
        return AppsView(onOpenSystemApp: _openSystemApp);
      case 3:
        return const MessagesView();
      case 4:
        return const WalletView();
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildAppBar(BuildContext context, GlassTokens tokens) {
    // Blur dropped — was costing per-frame GPU time for an effect that
    // wasn't visually noticeable. Bumped opacity to keep the bar legible
    // when content scrolls beneath it.
    // The bar's content sits in one rounded panel, like desktop's rail
    // (borderless, the fill carries the edge), in the bottom-nav selection
    // colour.
    return Container(
      color: tokens.background.withValues(alpha: 0.95),
      height: kToolbarHeight,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      // Radius ≈ the avatar's (an individual's: 40 % of its 32 px = 12.8)
      // plus the 8 px inset, so the two corners run parallel. Fill one step
      // darker than the nav pill.
      child: Container(
        padding: const EdgeInsets.only(left: 4, right: 4),
        decoration: BoxDecoration(
          color: tokens.surfaceElevated,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: ListenableBuilder(
                    listenable: AppStateNotifier.instance!,
                    builder: (context, _) {
                      final me = AppStateNotifier.currentMyContact;
                      return Row(
                        children: [
                          // 32 px, with 8 px of panel around it on every side.
                          GestureDetector(
                            onTap: () => AppNav.toMyProfile(context),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: GlassContactIcon(
                                contact: me,
                                address:
                                    me?.publicosAddress?.eip55With0x ?? '',
                                size: 32,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              me?.publicosDisplayName ??
                                  me?.displayName ??
                                  '',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: tokens.starkWhite,
                                letterSpacing: 0.5,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _NotificationBell(
                      unread: _unreadCount,
                      onTap: () async {
                        await Navigator.of(context).push(
                          CupertinoPageRoute(
                              builder: (_) => const NotificationsScreen()),
                        );
                        if (mounted) await _refreshUnreadCount();
                      },
                    ),
                    const SizedBox(width: 4),
                    _StatusIcon(
                      icon: Icons.link_rounded,
                      color: _chainIconColor(context),
                      onTap: () async {
                        await Navigator.of(context).push(
                          CupertinoPageRoute(
                              builder: (_) => const BspScreen()),
                        );
                        if (mounted) await _refreshAfterBspPop();
                      },
                    ),
                    const SizedBox(width: 4),
                    _StatusIcon(
                      icon: Icons.cloud_outlined,
                      color: _sspIconColor(context),
                      onTap: () async {
                        await Navigator.of(context).push(
                          CupertinoPageRoute(
                              builder: (_) => const SspScreen()),
                        );
                        if (mounted) await _refreshAfterSspPop();
                      },
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ],
            ),
          ),
        );
  }

  /// A bottom-nav glyph, with a filled pill behind it while its tab is
  /// selected (a pill whose flat run
  /// is about the icon's width: 32 tall, 56 wide = 24 flat). The fill is one
  /// step up from the bar, opaque, the styling guide's "pill above the
  /// screen" rule.
  Widget _navIcon(int index, GlassTokens tokens, Widget glyph) {
    final active = _currentIndex == index;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      width: 56,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: active
            ? Color.alphaBlend(tokens.glassFillHover, tokens.surfaceElevated)
            : Colors.transparent,
      ),
      child: glyph,
    );
  }

  Widget _buildBottomNav(BuildContext context, GlassTokens tokens) {
    // Blur dropped — same reasoning as the AppBar above.
    return Container(
      decoration: BoxDecoration(
        color: tokens.background.withValues(alpha: 0.95),
        border: Border(
          top: BorderSide(color: tokens.borderSubtle, width: 1),
        ),
      ),
      // EXPERIMENT: the SizedBox overrides BottomNavigationBar's hard-coded
      // 56px minHeight (a parent constraint wins over the child's
      // ConstrainedBox). Drop the SizedBox to restore Material height.
      child: SizedBox(
        height: _kExperimentNavHeight + MediaQuery.viewPaddingOf(context).bottom,
        child: BottomNavigationBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        currentIndex: _currentIndex,
        selectedItemColor: tokens.starkWhite,
        unselectedItemColor: tokens.textDim,
        // EXPERIMENT: icons-only bottom nav. Swap the four lines back to
        // the commented values to restore labels. Item `label:`s stay for
        // a11y semantics. Font size 0 matters even with labels hidden: the
        // tile still reserves `selectedFontSize` as top padding otherwise,
        // which is what pushed the icons low.
        // showSelectedLabels: true,
        // showUnselectedLabels: true,
        // selectedFontSize: 11,
        // unselectedFontSize: 11,
        showSelectedLabels: false,
        showUnselectedLabels: false,
        selectedFontSize: 0,
        unselectedFontSize: 0,
        onTap: (i) {
          // Feeds is showing → its button is a hamburger: open the lists
          // drawer instead of switching.
          if (i == 0 && _currentIndex == 0) {
            _feedsKey.currentState?.toggleDrawer();
            return;
          }
          setState(() => _currentIndex = i);
          // Tab tap on Feeds = silent refresh: re-pull lists/channels in the
          // background but keep the loaded feed on screen. A loud refresh here
          // tore the body down to a spinner and remounted PostsList, which is
          // what produced the doubled loading animation on re-entry.
          if (i == 0) {
            _feedsKey.currentState?.refresh(silent: true);
          }
        },
        items: [
          BottomNavigationBarItem(
            // A hamburger while Feeds is showing (it opens the lists drawer),
            // the feeds glyph everywhere else.
            icon: _navIcon(
              0,
              tokens,
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                transitionBuilder: (child, anim) => RotationTransition(
                  turns: Tween<double>(begin: 0.75, end: 1).animate(anim),
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: _currentIndex == 0
                    ? const Icon(Icons.menu_rounded,
                        key: ValueKey('feeds-menu'))
                    : const Icon(Icons.rss_feed_rounded,
                        key: ValueKey('feeds-tab')),
              ),
            ),
            label: context.l10n.explorerTabFeeds,
          ),
          BottomNavigationBarItem(
            icon: _navIcon(1, tokens, const Icon(Icons.people_outline_rounded)),
            label: context.l10n.explorerTabContacts,
          ),
          BottomNavigationBarItem(
            icon: _navIcon(2, tokens, const Icon(Icons.apps_rounded)),
            label: context.l10n.explorerTabApps,
          ),
          BottomNavigationBarItem(
            icon: _navIcon(3, tokens, const Icon(Icons.message_outlined)),
            label: context.l10n.explorerTabMessages,
          ),
          BottomNavigationBarItem(
            icon: _navIcon(
                4, tokens, const Icon(Icons.account_balance_wallet_outlined)),
            label: context.l10n.explorerTabWallet,
          ),
        ],
        ),
      ),
    );
  }
}

/// EXPERIMENT: icons-only bottom nav height. Material's default is 56
/// (`kBottomNavigationBarHeight`); 48 keeps the Material minimum touch
/// target. Remove together with the other EXPERIMENT blocks in this file.
const double _kExperimentNavHeight = 48;

class _StatusIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _StatusIcon({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Icon(icon, size: 20, color: color),
      ),
    );
  }
}

/// App-bar notification bell with an unread badge. Active (filled + starkWhite)
/// when there's unread activity, idle (outline + textDim) otherwise. Prepended
/// leftmost of the chain + SSP status icons.
class _NotificationBell extends StatelessWidget {
  final int unread;
  final VoidCallback onTap;

  const _NotificationBell({required this.unread, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final on = unread > 0;
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(
              on
                  ? Icons.notifications_rounded
                  : Icons.notifications_none_rounded,
              size: 20,
              color: on ? tokens.starkWhite : tokens.textDim,
            ),
            if (on)
              Positioned(
                top: -4,
                right: -5,
                child: _UnreadBadge(count: unread),
              ),
          ],
        ),
      ),
    );
  }
}

/// Teal unread pill: a number for 1–99, a bare dot above 99.
class _UnreadBadge extends StatelessWidget {
  final int count;

  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final ring = Border.all(color: tokens.background, width: 1.5);
    if (count > 99) {
      return Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: tokens.connectedAccent,
          shape: BoxShape.circle,
          border: ring,
        ),
      );
    }
    return Container(
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: tokens.connectedAccent,
        borderRadius: BorderRadius.circular(8),
        border: ring,
      ),
      child: Center(
        child: Text(
          '$count',
          style: TextStyle(
            fontSize: 10,
            height: 1,
            fontWeight: FontWeight.w700,
            color: tokens.background,
          ),
        ),
      ),
    );
  }
}
