// The app's one embedded webview.
//
// **This widget is presentation and gesture only.** The EIP-1193 provider, the
// request dispatch, the connect-grant gate and every line that touches a key
// live in `publicos_web3_bridge`, shared with publicos_desktop so that code
// exists exactly once. What stays here is what genuinely differs between the
// two clients: the engine (`webview_flutter`), the consent chrome (bottom
// sheets), first-party route interception (GoRouter), and pull-to-refresh.
//
// The four seams are implemented in `web3_adapters.dart`.

import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:publicos_web3_bridge/publicos_web3_bridge.dart';
// Only for the `overrideSigningKey` field's type -- the widget never uses a key
// for anything, it just carries the wallet-manager's pin down to the binding.
import 'package:web3dart/web3dart.dart' show EthPrivateKey;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'package:publicos_client/components/pixel_rain_loading_label.dart';
import 'package:publicos_client/components/browser/web3_adapters.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/data/chain_registry.dart';
import 'package:publicos_client/router.dart';

/// If [url] is a publicos.dev URL the app has a NATIVE route for, return the
/// path (+ query) to push through GoRouter; otherwise null.
///
/// App Links / Universal Links only fire for OS-level link opens, NOT for
/// navigations that happen INSIDE a webview. So an in-page link to a first-party
/// route — e.g. a Quests "claim <id>" button pointing at
/// `https://publicos.dev/publicosAddress/<org>/chat/support?message=claim <id>` —
/// would otherwise just load the *website* inside this webview. We mirror the same
/// path prefixes the OS-level App Links claim (AndroidManifest / apple-app-site-
/// association) and hand those to the native router instead.
String? internalPublicosRoute(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host != 'publicos.dev') return null;
  const prefixes = ['/publicosAddress/', '/inboxId/', '/conversationTopic/'];
  if (!prefixes.any(uri.path.startsWith)) return null;
  // preserve the query verbatim (e.g. ?message=claim%20set_avatar drives the
  // chat compose prefill) — reconstruct path+query, drop the origin.
  return uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
}

/// Web3-enabled WebView wrapper for PublicOS
///
/// This component wraps the standard WebView with Web3 provider injection,
/// enabling dApps to interact with the user's wallet through window.ethereum
class PublicOSWebView extends StatefulWidget {
  final String initialUrl;
  final Function(String)? onError;
  final Function(String)? onPageFinished;

  /// Fired once the underlying [WebViewController] is created, so the host
  /// (the Browser) can hold a handle for `goBack()`.
  final void Function(WebViewController controller)? onControllerCreated;

  /// Fired on every navigation edge with the current `canGoBack()` state, so
  /// the host can mirror it synchronously (drives the back chevron + the
  /// Android system-back interception).
  final void Function(bool canGoBack)? onCanGoBackChanged;

  /// Pins the browser to a SPECIFIC account instead of the global web-selected
  /// key. Set by the Manage-wallet sheet to the wallet the user pressed
  /// "Manage" on — its `address` (a Safe address for a Safe, the EOA for a
  /// keychain key). When null (the standalone Browser), the global
  /// web-selected key is used.
  final String? overrideAccountAddress;

  /// The key that signs for [overrideAccountAddress]: the keychain key for an
  /// EOA wallet, or the account owner key for a Safe (EIP-1271 / Safe-routing
  /// is deferred). When null, signing falls back to the web-selected/session key.
  final EthPrivateKey? overrideSigningKey;

  /// Fired whenever this page's CONNECTION state changes — `true` on a fresh
  /// grant (connect sheet) or a returning-granted load, `false` on an ungranted
  /// load or a web-key switch to a key this origin lacks. The host lights or
  /// hides the address-bar key indicator in response (§07). It is a connect
  /// *event*, never a bare tab re-display.
  final void Function(bool connected)? onConnectionChanged;

  /// The address the page now sees first, or null — fired beside
  /// [onConnectionChanged] so the host's key chip can show which key this site
  /// is using.
  final void Function(String? address)? onActiveAccountChanged;

  /// A counter the host bumps whenever this site's PERMISSION changed outside
  /// the provider — the key indicator's picker closing, a revoke in the
  /// keychain.
  ///
  /// It is a revision number rather than the preferred-key label on purpose:
  /// switching the preferred key does not change what a site may see, so
  /// watching that label would re-evaluate the page on a non-event and miss
  /// the real one. A revision number says
  /// only "grants moved, re-read them", which is exactly what the host knows.
  final int grantsRevision;

  /// Hands the host THIS page's [ChainRegistry], once, when the bridge is
  /// built — so the address bar can show which chain the tab is on and move it.
  ///
  /// The registry stays owned by this webview, which is the invariant that
  /// matters: it is created and discarded with the page, so a switch moves one
  /// tab and can never leak into another (the chain is per-webview).
  /// The host holds the reference only to read
  /// `currentChainId` and call `switchChain`, and must drop it when the webview
  /// is rebuilt.
  final void Function(ChainRegistry registry)? onChainRegistryCreated;

  /// The tab's chain moved — by a page calling `wallet_switchEthereumChain`, or
  /// by the user. Carries the new `0x`-prefixed id so chrome can re-render
  /// without polling the registry.
  final void Function(String chainId)? onChainChanged;

  /// Whether this page is denied the Web3 wallet bridge entirely.
  ///
  /// **Defaults to FALSE — every existing surface keeps the bridge exactly as
  /// it always had it.** App tabs, website-record tabs and the Manage-wallet
  /// sheet are all unchanged by this parameter's existence.
  ///
  /// It exists for **app cards** (`cardKind: 'app'`), which pass `true`. A card
  /// is not a tab: it mounts on a profile someone is merely *reading*, with no
  /// navigation act behind it at all. Handing that a wallet would let a page
  /// fire signature prompts at a visitor who was scrolling past a stranger's
  /// profile — a materially weaker consent signal than any tab has, which is
  /// why cards are the one surface sandboxed by default while nothing else is.
  ///
  /// When true, two things do not happen: the JS channel is never registered,
  /// and `_injectProvider` returns early. A sandboxed page therefore has no
  /// provider to find AND no channel to post to, so there is no half-open
  /// state where a page can talk to a bridge that will not answer.
  ///
  /// ⚠ This deliberately does NOT decide whether *website-record* tabs should
  /// also lose the bridge. That is a
  /// separate call about existing behaviour and remains open; this parameter is
  /// the mechanism it would use, not the decision itself.
  final bool sandboxed;

  /// Render as an **app card** rather than a browser page.
  ///
  /// A card is a small tile inside a scrolling, reorderable grid, not a tab. So
  /// card mode drops everything that only makes sense for a tab:
  ///
  /// - **no pull-to-refresh.** The gesture machinery exists so a page can be
  ///   refreshed by dragging; inside a grid that same drag is the user
  ///   scrolling their profile, and competing for it is how a card would make
  ///   the whole page feel broken.
  /// - **no debug panel, no pull indicator** — chrome a tile has no room for.
  /// - **no error screen and no loading spinner.** Both render *nothing*, which
  ///   is the point: the card paints its own still image underneath, so an
  ///   unloaded or failed live half simply leaves the image showing. The image
  ///   never unmounts, and "mounting" is not a visible state.
  ///
  /// Deliberately ORTHOGONAL to [sandboxed]. Card mode is about chrome and
  /// gestures; [sandboxed] is about the wallet bridge. Cards pass `true` to
  /// both today, but giving cards web3 later is flipping one boolean, not
  /// disentangling two concerns.
  final bool cardMode;

  /// When set, the page may not navigate outside this URL prefix.
  ///
  /// A webview that can navigate anywhere is a browser, and a card has no URL
  /// bar to tell the viewer where they ended up. So an app card pins its live
  /// half to the app's on-chain `card_origin` and refuses anything else --
  /// off-origin links are handed to [onOffOriginNavigation] (the host opens a
  /// real Browser tab, where chrome and the permission model both exist).
  ///
  /// Null = unrestricted, which is every browser tab.
  final Uri? allowedOrigin;

  /// Called with a navigation this view refused because of [allowedOrigin].
  final void Function(String url)? onOffOriginNavigation;

  /// Which storage profile -- cookies, localStorage, IndexedDB, cache --
  /// this page lives in. `null` = the current session's own jar
  /// ([WebStorageProfileId.account]). The wallet-manager sheet passes
  /// [WebStorageProfileId.wallet] so the wallet dApp never shares a jar with
  /// an app tab of the same account.
  final String? profileId;

  /// The fifth seam: builds the engine controller for [profileId]. Defaults
  /// to this app's implementation; injectable so a test can hand in a fake.
  final WebStorageProfile<WebViewController> storage;

  const PublicOSWebView({
    super.key,
    required this.initialUrl,
    this.onError,
    this.onPageFinished,
    this.onControllerCreated,
    this.onCanGoBackChanged,
    this.overrideAccountAddress,
    this.overrideSigningKey,
    this.onConnectionChanged,
    this.onActiveAccountChanged,
    this.onChainRegistryCreated,
    this.onChainChanged,
    this.grantsRevision = 0,
    this.sandboxed = false,
    this.cardMode = false,
    this.allowedOrigin,
    this.onOffOriginNavigation,
    this.profileId,
    this.storage = const ClientWebStorage(),
  });

  @override
  State<PublicOSWebView> createState() => _PublicOSWebViewState();
}

class _PublicOSWebViewState extends State<PublicOSWebView> {
  WebViewController? _controller;
  String? _error;
  bool _showDebugPanel = false;
  final List<String> _debugLogs = [];

  /// Dev-only floating log-panel toggle (the red bug icon, bottom-right). Off
  /// by default — it cluttered the webview. Flip to true when you need the
  /// in-webview gesture/Web3 log (it is still additionally kDebugMode-gated, so
  /// a release build has no logs and no button regardless).
  static const bool _debugButtonEnabled = false;

  // ── PULL TO REFRESH ────────────────────────────────────────────────────────
  //
  // The WebView is a PLATFORM VIEW, and that dictates the whole design here.
  //
  // The textbook recipe — a RefreshIndicator over a Scrollable wrapping the
  // WebView — does not work. WebViewWidget declares no gestureRecognizers, so a
  // Scrollable above it WINS every vertical drag in the gesture arena and the
  // page can no longer scroll AT ALL. Hand the WebView a drag recognizer so it
  // scrolls again, and now the RefreshIndicator never sees a drag. It is a real
  // either/or, not a tuning problem.
  //
  // The way out: a Listener does NOT enter the gesture arena — it OBSERVES raw
  // pointer events no matter who wins them. So the WebView keeps 100% of its
  // native scrolling and we simply watch alongside it. We know the page's scroll
  // offset from setOnScrollPositionChange, and a downward drag while the page is
  // at the top is unambiguous: there is nothing there for the page to scroll, so
  // we are not stealing a gesture from it.
  //
  // Nothing about the Web3 bridge, the arena, or the platform view changes.

  /// The page's own scroll offset, mirrored from the WebView. `<= 0` means the
  /// page is at the top (iOS reports NEGATIVE while rubber-band bouncing, which
  /// is why this is `<= 0` and not `== 0`).
  double _scrollY = 0;

  /// How far the pull has been dragged, in logical pixels AFTER resistance.
  /// 0 = no pull in progress.
  double _pull = 0;

  /// True while a finger is actively pulling — drives the snap-back animation
  /// (instant while dragging, eased on release).
  bool _dragging = false;

  /// True from the moment we call reload() until the page finishes. The spinner
  /// stays parked at [_restPull] and further pulls are ignored.
  bool _refreshing = false;

  /// Where the pull started, so the drag distance is measured from the point the
  /// page ran out of scroll — not from where the finger first touched down.
  double? _pullAnchorY;

  /// Multi-touch (a pinch-zoom) is never a pull.
  int _pointers = 0;

  /// Drag past this (post-resistance) and the release refreshes.
  static const double _pullThreshold = 64;

  /// Hard cap, so a long drag does not fling the spinner down the screen.
  static const double _maxPull = 96;

  /// Where the spinner parks while the reload is in flight.
  static const double _restPull = 56;

  /// Resistance: the spinner travels at half the finger's speed, which is what
  /// makes the gesture feel like it is pulling against something.
  static const double _pullResistance = 0.5;

  // Hardcoded chain ID to RPC URL mapping

  // ── the bridge ──────────────────────────────────────────────────────────
  //
  // Built once the controller exists, torn down with the widget. The widget
  // never reaches past these: it feeds the host lifecycle events and page
  // messages, and reads `_chains.currentChainId` for display.

  WebViewFlutterHost? _host;
  Web3Dispatcher? _dispatcher;
  ConnectGate? _gate;
  // The chain list comes from the APP, not the package: `kBridgeChainRpcMap`
  // is derived from `lib/data/chain_registry.dart`, the same file the Send
  // sheet, the network pills and the brand marks read. The bridge's own
  // `defaultChains` stays a standalone fallback we never take, which is what
  // stops the browser and the wallet drifting onto different endpoints for
  // the same chain.
  late final ChainRegistry _chains = ChainRegistry(
    chains: kBridgeChainRpcMap,
    onChainChanged: (id) {
      // The page first (it is the spec's audience), then the chrome.
      _channel?.emit(Web3Events.chainChanged, id);
      widget.onChainChanged?.call(id);
    },
    log: _log,
  );
  Web3Channel? _channel;

  /// The origin of the document currently loaded, as the bridge sees it.
  /// Updated on every navigation edge, because an SPA can move without one.
  Uri? _currentOrigin;

  String get _chainId => _chains.currentChainId;

  /// Reads `widget.` through closures on every call, NOT captured once.
  ///
  /// The wallet manager builds this webview BEFORE its managed key has
  /// resolved -- it kicks off `exportPrivateKey` in `initState` and renders
  /// immediately, so the first build passes `null` and the key arrives a frame
  /// or two later via `setState`. A captured value would freeze that `null` for
  /// the life of the bridge, and every signature would fall back to the
  /// web-selected key instead of the pinned wallet's: the page told one
  /// address, signing with another.
  ///
  /// The pre-refactor code avoided this by reading `widget.overrideSigningKey`
  /// fresh inside `_resolveSigningKey` on every signature. This restores that.
  SessionWalletBinding get _wallet => SessionWalletBinding(
        userAddressOf: () =>
            AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x,
        overrideAccountAddressOf: () => widget.overrideAccountAddress,
        overrideSigningKeyOf: () => widget.overrideSigningKey,
      );

  void _buildBridge(WebViewController controller) {
    final host = WebViewFlutterHost(controller);
    final channel = HostWeb3Channel(host, log: _log);
    final wallet = _wallet;

    final gate = ConnectGate(
      wallet: wallet,
      grants: const CoreGrantStore(),
      consent: SheetWeb3Consent(
        contextOf: () => mounted ? context : null,
        chainIdOf: () => _chainId,
      ),
      channel: channel,
      // Session, not account: a user can hold several sessions for one account
      // on one device, and an account-scoped grant cannot tell them apart.
      sessionAddress: (PublicOS.sessionBlockchainAddress ??
              '0x0000000000000000000000000000000000000000')
          .toLowerCase(),
      onConnectionChanged: (c) => widget.onConnectionChanged?.call(c),
      onActiveAccountChanged: (a) => widget.onActiveAccountChanged?.call(a),
      log: _log,
    );

    _host = host;
    _channel = channel;
    _gate = gate;
    _dispatcher = Web3Dispatcher(
      gate: gate,
      wallet: wallet,
      consent: SheetWeb3Consent(
        contextOf: () => mounted ? context : null,
        chainIdOf: () => _chainId,
      ),
      channel: channel,
      chains: _chains,
      rpc: HttpWeb3Rpc(_chains, log: _log),
      transactions: ChainTransactionExecutor(_chains, log: _log),
      currentOrigin: () => _currentOrigin,
      // Unrestricted for now: the scope safeguard ships with its policy
      // permissive, so that adding real enforcement later is changing a value
      // rather than threading a parameter through every construction site.
      log: _log,
    );
  }

  /// Install the EIP-1193 provider into the page.
  ///
  /// **On page-finish, not document-start.** `webview_flutter` exposes neither
  /// Android's `addDocumentStartJavaScript` nor iOS's `WKUserScript`, so a dApp
  /// that reads `window.ethereum` before its own first script runs wins the
  /// race. WebView2 on desktop does not have this problem, which is why
  /// `WebViewHost` reports the capability rather than pretending parity.
  ///
  /// Grant-aware: an address is baked in ONLY for an origin that already holds
  /// a grant, so a returning user is not re-prompted and a reading dApp
  /// re-hydrates synchronously. Every other origin is injected identity-less
  /// and must go through the door.
  ///
  /// `selectedAddress` is a scalar, so it gets `accounts[0]` — the preferred
  /// key if this site holds it, otherwise the first permitted key in keychain
  /// order. The rest of the set arrives on the page's first `eth_accounts`,
  /// which answers from the same ordering, so the two can never disagree.
  Future<void> _injectProvider() async {
    // Second of the three guards (see the controller setup). A sandboxed page
    // never reaches here with a gate anyway, because the bridge was never
    // built -- this is the explicit statement of intent rather than a
    // side-effect of null-checks.
    if (widget.sandboxed) return;
    final gate = _gate;
    final host = _host;
    if (gate == null || host == null) return;

    final accounts = await gate.grantedAccounts(_currentOrigin);
    final granted = accounts.isNotEmpty;
    final address = granted ? accounts.first : null;

    _log('[PublicOSWebView] injecting provider '
        '(granted: ${accounts.length} key(s), chain: $_chainId, '
        'pinned: ${widget.overrideAccountAddress != null})');

    try {
      await host.runJavaScript(buildProviderScript(
        address: address,
        chainId: _chainId,
        transport:
            BridgeTransport.javaScriptChannel(WebViewFlutterHost.channelName),
      ));
      // A granted load IS a connect event (lights the chip); an ungranted one
      // reports false, which hides a chip left over from the previous page.
      widget.onConnectionChanged?.call(granted);
      widget.onActiveAccountChanged?.call(address);
    } catch (e) {
      _log('[PublicOSWebView] provider injection failed: $e');
    }
  }

  String _getUserAgentForUrl(String url) {
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? '';

    // Sites that should get desktop user agent
    const desktopSites = ['warpcast.com', 'www.warpcast.com'];

    if (desktopSites.contains(host)) {
      // Desktop Chrome user agent
      return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    }

    // Default mobile user agent
    return 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
  }

  void _log(String message) {
    // Production perf: _log fires on every WebView callback — onProgress
    // ticks, onUrlChange, and every Web3 RPC request/response. The
    // print() + setState() combo recomposited the platform view many
    // times/sec and tanked WebView FPS in release. Gate to debug builds
    // only; the Web3 handling itself is untouched (only the logging is
    // dropped). Debug builds keep the full log panel + copy/clear tools.
    if (!kDebugMode) return;
    // ignore: avoid_print
    print(message);
    if (mounted) {
      setState(() {
        _debugLogs.add('[${DateTime.now().toString().substring(11, 19)}] $message');
        // Keep last 100 logs
        if (_debugLogs.length > 100) {
          _debugLogs.removeAt(0);
        }
      });
    }
  }


  @override
  void initState() {
    super.initState();
    // Hand the chrome this page's registry and its starting chain. Done here
    // rather than in the bridge builder so a sandboxed page (no bridge) still
    // reports the chain it reads on — and POST-FRAME, because initState runs
    // inside the host's build and the host answers these by calling setState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onChainRegistryCreated?.call(_chains);
      widget.onChainChanged?.call(_chains.currentChainId);
    });
    _initializeController();
  }

  @override
  void didUpdateWidget(PublicOSWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialUrl != oldWidget.initialUrl) {
      _controller?.loadRequest(Uri.parse(widget.initialUrl));
    }
    // This site's permission changed while the page is running. Re-read the
    // set and tell the page: still granted -> re-announce it, disconnected ->
    // `accountsChanged([])` and the chip hides. Only fires when the URL is
    // unchanged -- a URL change reloads and re-injects anyway.
    if (widget.grantsRevision != oldWidget.grantsRevision &&
        widget.initialUrl == oldWidget.initialUrl) {
      _gate?.refresh(_currentOrigin);
    }
  }

  Future<void> _initializeController() async {
    _log('[PublicOSWebView] Initializing controller for: ${widget.initialUrl}');
    _currentOrigin = Uri.tryParse(widget.initialUrl);

    // A missing session address is the zero address, not null: the profile id
    // is part of the storage path, and a mounted webview with no session is
    // the pre-login card preview, which must still get SOME jar of its own.
    final String profile = widget.profileId ??
        WebStorageProfileId.account(
          PublicOS.sessionBlockchainAddress ??
              '0x0000000000000000000000000000000000000000',
        );

    final WebViewController controller;
    try {
      controller = await widget.storage.createController(profile);
    } catch (e) {
      _log('[PublicOSWebView] storage profile "$profile" failed: $e');
      if (mounted) setState(() => _error = '$e');
      widget.onError?.call('$e');
      return;
    }
    if (!mounted) return;

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Opaque surface: a transparent platform-view surface forces per-frame
      // alpha compositing against the Flutter scene and defeats the fast opaque
      // TLHC path, at a major FPS cost. 0xFF15181c matches the glass-dark app
      // chrome so the pre-paint flash is not jarring.
      ..setBackgroundColor(const Color(0xFF15181c))
      ..setUserAgent(_getUserAgentForUrl(widget.initialUrl));

    if (controller.platform is AndroidWebViewController) {
      (controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(true);
    }

    // The page's scroll offset, mirrored for pull-to-refresh. The ONLY thing
    // that tells us the page has run out of scroll. Fires often: keep it a bare
    // field write, never a setState.
    controller.setOnScrollPositionChange((ScrollPositionChange change) {
      final wasTop = _scrollY <= 0;
      final isTop = change.y <= 0;
      if (wasTop != isTop) {
        _pullLog('scroll ${isTop ? "AT TOP" : "left the top"} '
            '(y=${change.y.toStringAsFixed(1)})');
      }
      _scrollY = change.y;
    });

    // Sandboxed pages get NO bridge at all: no dispatcher, and below, no JS
    // channel and no provider injection. Skipping construction (rather than
    // building it and refusing to answer) means there is nothing for a page to
    // reach even if a future edit forgets one of the other two guards.
    if (!widget.sandboxed) {
      _buildBridge(controller);
      controller.addJavaScriptChannel(
        WebViewFlutterHost.channelName,
        onMessageReceived: (JavaScriptMessage message) {
          // Straight to the bridge. The widget does not read, validate or
          // route these -- it does not know what an EIP-1193 request is.
          _dispatcher?.handle(message.message);
        },
      );
    } else {
      _log('[PublicOSWebView] SANDBOXED - no Web3 bridge for this page');
    }

    controller
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            _log('[PublicOSWebView] Page started: $url');
            _currentOrigin = Uri.tryParse(url);
            // A new page starts at the top. Reset rather than waiting for the
            // first scroll event, or a page navigated away from mid-scroll
            // leaves a stale offset and the first pull is ignored.
            _scrollY = 0;
            _emitCanGoBack();
          },
          onPageFinished: (String url) async {
            _log('[PublicOSWebView] Page finished: $url');
            _currentOrigin = Uri.tryParse(url);
            await _injectProvider();
            widget.onPageFinished?.call(url);
            _emitCanGoBack();
            _endRefresh();
          },
          onWebResourceError: (WebResourceError error) {
            final errorMsg = error.description;
            _log('[PublicOSWebView] Resource error: $errorMsg '
                '(isMainFrame: ${error.isForMainFrame})');
            // A refresh that FAILED still has to clear the spinner, or a pull
            // on a dead page parks it forever.
            _endRefresh();
            if (error.isForMainFrame == true) {
              setState(() => _error = 'Error loading page: $errorMsg');
              widget.onError?.call(errorMsg);
            }
          },
          onNavigationRequest: (NavigationRequest request) {
            // A link to a first-party PublicOS route (a Quests claim button,
            // say) must open the NATIVE screen, not load the website inside
            // this webview.
            final route = internalPublicosRoute(request.url);
            if (route != null) {
              _log('[PublicOSWebView] -> intercepting to native route: $route');
              if (mounted) GoRouter.of(context).push(route);
              return NavigationDecision.prevent;
            }
            // The teardown navigation. `dispose` below loads about:blank to
            // discard the document, and on iOS WKWebView routes programmatic
            // loads through this very gate (Android does not). Refusing it
            // here would both surface "Could not launch about:blank" through
            // onOffOriginNavigation AND cancel the teardown, leaving the
            // demoted page running. It is the one navigation this view
            // issues to itself, so it is exempt from the origin lock.
            if (request.url == 'about:blank') {
              return NavigationDecision.navigate;
            }
            // Origin lock. Checked with the SAME component-wise comparison the
            // card resolver used to decide this card was trustworthy in the
            // first place -- a `startsWith` here would let
            // `cards.example.app.evil.com` back in through the side door after
            // the resolver kept it out of the front.
            final origin = widget.allowedOrigin;
            if (origin != null) {
              final target = Uri.tryParse(request.url);
              if (target == null || !AppCardRef.isUnder(target, origin)) {
                _log('[PublicOSWebView] -> off-origin, refused: ${request.url}');
                widget.onOffOriginNavigation?.call(request.url);
                return NavigationDecision.prevent;
              }
            }
            return NavigationDecision.navigate;
          },
          onUrlChange: (UrlChange change) {
            // Single-page apps navigate via history.pushState, which fires no
            // onPageStarted/onPageFinished. Track the origin here too, because
            // the bridge's scope check reads it on every request -- this is the
            // only hook that sees an SPA move.
            if (change.url != null) _currentOrigin = Uri.tryParse(change.url!);
            _log('[PublicOSWebView] URL changed: ${change.url}');
            _emitCanGoBack();
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.initialUrl));

    if (!mounted) return;
    setState(() => _controller = controller);
    widget.onControllerCreated?.call(controller);
    _emitCanGoBack();
  }

  void _pullLog(String msg) => _log('[pull] $msg');

  void _onPointerDown(PointerDownEvent e) {
    _pointers++;
    _pullLog('down (pointers=$_pointers, scrollY=${_scrollY.toStringAsFixed(1)})');
    // A second finger means pinch-zoom, not a pull. Abandon whatever we had.
    if (_pointers > 1) _cancelPull();
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_pointers != 1 || _refreshing || _controller == null) return;

    // The page has scroll left to give — it owns this drag, not us. This also
    // ABORTS a pull in progress: pull down, page starts scrolling somehow, the
    // spinner must let go rather than hover over a scrolling page.
    if (_scrollY > 0) {
      if (_pull != 0) {
        _pullLog('abort — page scrolled (scrollY=${_scrollY.toStringAsFixed(1)})');
        _cancelPull();
      }
      return;
    }

    // Start the pull at the moment the page is at the top AND the finger is
    // moving down — not at pointer-down. That way a user who scrolls up to the
    // top and keeps dragging in the SAME gesture gets the pull, exactly like
    // every native list does.
    if (_pullAnchorY == null) {
      if (e.delta.dy <= 0) return;
      _pullAnchorY = e.position.dy;
      _dragging = true;
      _pullLog('START at dy=${e.position.dy.toStringAsFixed(0)}');
    }

    final raw = e.position.dy - _pullAnchorY!;
    // Dragged back UP past the start: the user changed their mind.
    if (raw <= 0) {
      _pullLog('abort — dragged back up');
      _cancelPull();
      return;
    }
    final next = (raw * _pullResistance).clamp(0.0, _maxPull);
    // Log only when the threshold is CROSSED, not on every pixel.
    if (next >= _pullThreshold && _pull < _pullThreshold) {
      _pullLog('armed (${next.toStringAsFixed(0)} >= $_pullThreshold) — release to refresh');
    }
    if (next != _pull) setState(() => _pull = next);
  }

  void _onPointerUp(PointerEvent e) {
    _pointers = (_pointers - 1).clamp(0, 10);
    // ⚠ THE SUSPECT. onPointerCancel routes here too, and Android platform views
    // are entitled to make the framework cancel a pointer once the view claims the
    // gesture. If a CANCEL arrives on every drag, the pull is torn down before it
    // can ever accumulate — and pull-to-refresh silently never fires. This line is
    // how we find out, because a cancel and a genuine finger-lift are otherwise
    // indistinguishable from the outside.
    _pullLog('${e is PointerCancelEvent ? "CANCEL" : "up"} '
        '(pull=${_pull.toStringAsFixed(0)}/$_pullThreshold)');

    if (_refreshing || _pull == 0) {
      _cancelPull();
      return;
    }
    if (_pull >= _pullThreshold) {
      _pullLog('FIRE -> reload()');
      _refresh();
    } else {
      _pullLog('below threshold — snap back, no reload');
      _cancelPull(); // not far enough — snap back, load nothing
    }
  }

  void _cancelPull() {
    _pullAnchorY = null;
    if (_pull == 0 && !_dragging) return;
    setState(() {
      _pull = 0;
      _dragging = false;
    });
  }

  /// Reload, and park the spinner until the page reports it is done.
  ///
  /// `reload()` re-runs the SAME url through the full navigation delegate, so
  /// the Web3 provider is re-injected by the existing onPageFinished — a
  /// refreshed page gets a live `window.ethereum` exactly like a fresh load. We
  /// add nothing to that path.
  void _refresh() {
    _pullAnchorY = null;
    setState(() {
      _dragging = false;
      _refreshing = true;
      _pull = _restPull;
    });
    _controller?.reload();
  }

  /// Called from onPageFinished AND onWebResourceError: a refresh that FAILED
  /// still has to clear the spinner, or a dead page leaves it parked forever.
  void _endRefresh() {
    if (!_refreshing) return;
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      _pull = 0;
      _dragging = false;
    });
  }

  /// Re-query the controller's history depth and report it to the host.

  Future<void> _emitCanGoBack() async {
    final canGoBack = await _controller?.canGoBack() ?? false;
    if (mounted) widget.onCanGoBackChanged?.call(canGoBack);
  }

  /// Inject Web3 provider JavaScript into the page.
  ///
  /// The injected `selectedAddress` MUST match what `eth_accounts` returns and
  /// what we sign with — i.e. the web-selected key, NOT the main account. We
  /// re-resolve it on every injection (page finish) so a mid-session web-key
  /// change is reflected without a stale captured address.
  /// The address exposed to the dApp (selectedAddress / eth_accounts /
  /// permissions). A host-pinned account (the wallet pressed "Manage") wins;
  /// otherwise the global web-selected key.

  Widget _buildDebugPanel() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: _showDebugPanel ? 200 : 0,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.9),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        ),
        child: _showDebugPanel
            ? Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        Text(
                          'Debug Logs (${_debugLogs.length})',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 16, color: Colors.white54),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          tooltip: 'Copy logs',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _debugLogs.join('\n')));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Logs copied to clipboard'),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 16, color: Colors.white54),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          tooltip: 'Clear logs',
                          onPressed: () {
                            setState(() {
                              _debugLogs.clear();
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Colors.white24),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.all(8),
                      itemCount: _debugLogs.length,
                      reverse: true,
                      itemBuilder: (context, index) {
                        final log = _debugLogs[_debugLogs.length - 1 - index];
                        final isError = log.contains('Error') || log.contains('error');
                        return SelectableText(
                          log,
                          style: TextStyle(
                            color: isError ? Colors.redAccent : Colors.white70,
                            fontSize: 10,
                            fontFamily: 'monospace',
                          ),
                        );
                      },
                    ),
                  ),
                ],
              )
            : null,
      ),
    );
  }

  Widget? _buildDebugButton({bool forceShow = false}) {
    final hasErrors = _debugLogs.any((log) => log.contains('Error') || log.contains('error'));
    // Only show debug button when there are errors, panel is open, or forced
    if (!forceShow && !hasErrors && !_showDebugPanel) return null;

    return Positioned(
      right: 8,
      bottom: _showDebugPanel ? 208 : 8,
      child: GestureDetector(
        onTap: () {
          setState(() {
            _showDebugPanel = !_showDebugPanel;
          });
        },
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            Icons.bug_report_outlined,
            size: 20,
            color: Colors.redAccent,
          ),
        ),
      ),
    );
  }

  @override

  Widget build(BuildContext context) {
    if (widget.cardMode) {
      // Nothing to show is the CORRECT rendering here, not a fallback: the card
      // paints its own image underneath this widget, so an error or a
      // still-loading engine just leaves that image visible. No spinner, no
      // error screen, and no Listener competing with the grid's scroll.
      if (_error != null || _controller == null) return const SizedBox.shrink();
      return WebViewWidget(controller: _controller!);
    }

    if (_error != null) {
      // Always show debug button on error screen
      return Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 48, color: Colors.red.withOpacity(0.7)),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: SelectableText(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ],
            ),
          ),
          _buildDebugPanel(),
          if (_debugButtonEnabled) _buildDebugButton(forceShow: true)!,
        ],
      );
    }

    if (_controller == null) {
      // The webview runs to the physical bottom edge.
      return const PixelRainLoadingCorner(safeBottom: true);
    }

    // The log panel exists but was only reachable once something had already gone
    // wrong (`hasErrors`) — useless for debugging a GESTURE, which fails silently and
    // logs no error at all. In debug builds, always offer it. `_log` is itself
    // kDebugMode-gated, so a release build has no logs to show and no button to show
    // them with: this changes nothing for a shipped app.
    final debugButton =
        _debugButtonEnabled ? _buildDebugButton(forceShow: kDebugMode) : null;
    return Stack(
      children: [
        // Listener, NOT GestureDetector: it observes pointers without entering
        // the gesture arena, so the WebView keeps every drag it would otherwise
        // have gotten. Behaviour stays `deferToChild` (the default) — we add no
        // hit-test surface of our own.
        Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerUp,
          child: WebViewWidget(controller: _controller!),
        ),
        if (_pull > 0) _buildPullIndicator(),
        _buildDebugPanel(),
        if (debugButton != null) debugButton,
      ],
    );
  }

  /// The pull indicator — our own, not Material's.
  ///
  /// It rides ON TOP of the page rather than pushing it down: we never move the
  /// WebView, because translating a platform view mid-gesture is exactly the
  /// kind of per-frame recomposition the FPS notes above warn about.
  ///
  /// PhigitalLoadingWidget is the canonical loading widget in this app — a
  /// Material CircularProgressIndicator here would be the only piece of stock
  /// Material chrome in the whole glass-dark browser.

  Widget _buildPullIndicator() {
    // Fade in over the first third of the pull, so a stray 5px drag doesn't
    // flash a spinner at the user.
    final progress = (_pull / _pullThreshold).clamp(0.0, 1.0);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: AnimatedContainer(
          // Instant while the finger drives it (the spinner must track the
          // finger 1:1 or the gesture feels laggy); eased on release, which is
          // the only moment we are animating rather than following.
          duration: _dragging ? Duration.zero : const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          alignment: Alignment.bottomCenter,
          height: _pull,
          child: Opacity(
            opacity: _refreshing ? 1.0 : progress,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: PhigitalLoadingWidget(
                size: 26,
                // Below the threshold the spinner is dimmed: the user can SEE
                // that letting go now would not refresh. Past it, it lights up.
                showShadows: _refreshing || progress >= 1.0,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override

  @override
  void dispose() {
    // ⚠ `webview_flutter` gives us NO WAY TO DESTROY the native view.
    // `WebViewController` has no `dispose()`, and dropping the Dart reference
    // does not tear down the Android WebView / WKWebView behind it: it keeps
    // running its document -- timers, JS and AUDIO -- until it is eventually
    // collected, which may be long after the widget is gone.
    //
    // That is not theoretical. Left alone, an app card's live half keeps
    // playing after being demoted, and promoting repeatedly stacks one audible
    // track per promotion. The desktop twin does not have the problem because
    // `zero_webview_windows` exposes a real `_controller.dispose()`.
    //
    // With no destroy available, navigating to about:blank IS the teardown:
    // it discards the document and everything running inside it. Fire and
    // forget -- the controller outlives this frame and there is nothing here
    // to await into. Wrapped because a view already torn down by the platform
    // will throw, and a dispose must never be the thing that crashes.
    final gone = _controller;
    _controller = null;
    if (gone != null) {
      try {
        gone.loadRequest(Uri.parse('about:blank')).ignore();
      } catch (_) {
        // already gone; nothing left to stop
      }
    }

    _host?.dispose();
    _host = null;
    _dispatcher = null;
    _gate = null;
    _channel = null;
    super.dispose();
  }
}
