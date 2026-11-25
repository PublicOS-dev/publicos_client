import 'dart:convert';

import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:publicos_client/components/browser/web3_adapters.dart'
    show ClientWebStorage;
import 'package:publicos_client/data/demo_contacts.dart';
import 'package:publicos_client/push_notifications_service.dart';
import 'package:publicos_client/router.dart';
import 'package:publicos_client/pages/browser.dart';
import 'package:publicos_client/pages/manage_inbox_ids_page.dart';
import 'package:publicos_client/l10n/boot_phase.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/utils/own_links.dart';
import 'package:publicos_client/utils/post_links.dart';

/// Runs the app initialization sequence and updates [AppStateNotifier]
/// at each milestone so GoRouter can redirect appropriately.
///
/// Extracted from body_container.dart's _initializeApp().
class AppInitializer {
  final AppStateNotifier appState;

  // Deep link handling
  static const _deepLinkChannel = MethodChannel('com.publicos/deeplink');

  AppInitializer(this.appState);

  /// Set up the native deep link method channel and notification tap handler.
  ///
  /// [router] is the GoRouter instance to push deep links to.
  void setupDeepLinkChannel(GoRouter router) {
    // Register notification tap handler
    PublicOS.onNotificationTapped = (type, identifier, {account}) {
      String? route;
      if (type == 'message') {
        route = '/conversationTopic/${Uri.encodeComponent(identifier)}';
      } else if (type == 'post') {
        // A social notification: the identifier is
        // the item's permalink; the page fetches it from its own host.
        route = '/post?url=${Uri.encodeQueryComponent(identifier)}';
      } else if (type == 'follow') {
        // A follow request: the owner's channel settings on its request
        // queue. The identifier is the channel URL.
        route = '/channel-requests?url=${Uri.encodeQueryComponent(identifier)}';
      } else if (type == 'channel') {
        // A follow approval: the channel's feed. The identifier is its URL.
        route = '/channel?url=${Uri.encodeQueryComponent(identifier)}';
      }
      if (route == null) return;

      if (appState.accountSelected) {
        // The popup names the account it was for: a tap meant for
        // another account goes nowhere but a toast.
        if (!_forThisAccount(account)) {
          print('AppInitializer: notification tap for another account, dropped');
          _toastLinkTargetNotFound(router);
          return;
        }
        if (_isAlreadyVisible(router, route)) return;
        router.push(route);
      } else {
        appState.setPendingRoute(route, forAccount: account);
      }
    };
    // The cold-start twin: the parked route is dropped by the auth gate when
    // a different account signs in.
    appState.onPendingRouteDropped = () => _toastLinkTargetNotFound(router);

    // A link_key key that arrived before sign-in opens once an account is up.
    appState.addListener(() => _openPendingKeyLink(router));

    _deepLinkChannel.setMethodCallHandler((call) async {
      if (call.method == 'onDeepLink') {
        final url = call.arguments as String;
        // An import_key link carries the words, a link_key link the key:
        // never print either.
        if (!url.startsWith('publicos://import_key/') &&
            !url.startsWith('publicos://link_key/')) {
          print('AppInitializer: Deep link received: $url');
        }
        _routeLink(router, url);
      }
    });

    // Links our own code opens take the same path, without leaving the app
    // (iOS never hands an app its own universal link back).
    ownLinkRouter = (url) {
      print('AppInitializer: Own link routed in-app: $url');
      return _routeLink(router, url);
    };

    // Pull cold-start deep link (may arrive before push handler was registered)
    _deepLinkChannel.invokeMethod<String>('getInitialLink').then((url) {
      if (url != null && url.isNotEmpty) {
        // Never print these: an import_key link carries the words, a
        // link_key link the key.
        if (_takeKeyImportLink(url, router: router)) return;
        if (_takeKeyLinkLink(url, router: router)) return;
        print('AppInitializer: Cold-start deep link: $url');
        final route = _parseDeepLinkToRoute(url);
        if (route != null) {
          appState.setPendingRoute(route);
        }
      }
    }).catchError((_) {
      // Platform doesn't support getInitialLink (e.g., web) — ignore
    });
  }

  /// A popup's payload may name the account it was for; no account = any.
  static bool _forThisAccount(String? account) {
    final me = PublicOS.myPublicosAddress;
    return account == null ||
        me == null ||
        account.toLowerCase() == me.toLowerCase();
  }

  /// "Link target not found": the tap was for another account.
  /// Shown on the next frame from the navigator's context, so it
  /// works from the auth gate's redirect as well as from a warm tap.
  static void _toastLinkTargetNotFound(GoRouter router) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = router.routerDelegate.navigatorKey.currentContext;
      if (ctx == null) return;
      ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
        SnackBar(
          content: Text(ctx.l10n.linkTargetNotFound),
          behavior: SnackBarBehavior.floating,
        ),
      );
    });
  }

  /// The one handler for a link arriving while the app runs: from the OS
  /// (`onDeepLink`) or from our own code ([ownLinkRouter]). Returns false
  /// only when [url] does not parse to a route.
  bool _routeLink(GoRouter router, String url) {
    if (_takeKeyImportLink(url, router: router)) return true;
    if (_takeKeyLinkLink(url, router: router)) return true;
    final route = _parseDeepLinkToRoute(url);
    if (route == null) {
      print('AppInitializer: Failed to parse deep link');
      return false;
    }

    if (appState.accountSelected) {
      // Warm start: navigate immediately
      if (_landInVisibleBrowser(route)) {
        print('AppInitializer: Landed $route in the visible Browser');
        return true;
      }
      if (_isAlreadyVisible(router, route)) {
        print('AppInitializer: Already on $route — skipping');
        return true;
      }
      print('AppInitializer: Warm start — navigating to $route');
      router.push(route);
    } else {
      // Cold start: store for redirect after auth
      print('AppInitializer: Cold start — storing pending route: $route');
      appState.setPendingRoute(route);
    }
    return true;
  }

  /// `publicos://import_key/<base64url of twelve words>/<name>`: the claim
  /// page's QR for an account whose words were made in a browser. It is not a
  /// route (the words never enter the router or a log): it is handed to the
  /// select-account screen, which asks before importing. Only before sign-in;
  /// a signed-in user is told to sign out first. True = the link was this kind.
  bool _takeKeyImportLink(String url, {required GoRouter router}) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'publicos' || uri.host != 'import_key') {
      return false;
    }
    final seg = uri.pathSegments;
    String words = '';
    try {
      if (seg.isNotEmpty) {
        words = utf8.decode(base64Url.decode(base64Url.normalize(seg[0]))).trim();
      }
    } catch (_) {}
    if (!RegExp(r'^[a-z]+( [a-z]+){11}$').hasMatch(words)) {
      print('AppInitializer: import_key link is not twelve words');
      return true;
    }
    if (appState.accountSelected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = router.routerDelegate.navigatorKey.currentContext;
        if (ctx == null) return;
        ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(
          content: Text(ctx.l10n.importKeyLinkSignedIn),
          behavior: SnackBarBehavior.floating,
        ));
      });
      return true;
    }
    appState.setPendingKeyImport(words, seg.length > 1 ? seg[1] : '');
    return true;
  }

  /// `publicos://link_key/<base64url of the 32 raw key bytes>`: another
  /// phone's keychain QR, "Add to another inbox" (the key handoff).
  /// Not a route: the key never enters the router or a log. It
  /// is parked in memory until an account is signed in, then handed to the
  /// Inbox IDs page, which asks which inbox to add it to and zeroes it.
  /// True = the link was this kind.
  bool _takeKeyLinkLink(String url, {required GoRouter router}) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'publicos' || uri.host != 'link_key') {
      return false;
    }
    final seg = uri.pathSegments;
    Uint8List? key;
    try {
      if (seg.isNotEmpty) {
        key = base64Url.decode(base64Url.normalize(seg[0]));
      }
    } catch (_) {}
    if (key == null || key.length != 32) {
      print('AppInitializer: link_key link is not a key');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = router.routerDelegate.navigatorKey.currentContext;
        if (ctx == null) return;
        ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(
          content: Text(ctx.l10n.linkKeyInvalid),
          behavior: SnackBarBehavior.floating,
        ));
      });
      return true;
    }
    appState.setPendingKeyLink(key);
    _openPendingKeyLink(router);
    return true;
  }

  /// Hand a parked link_key key to the Inbox IDs page once an account is
  /// signed in. Called on arrival and on every app-state change (sign-in).
  void _openPendingKeyLink(GoRouter router) {
    if (!appState.accountSelected) return;
    final key = appState.takePendingKeyLink();
    if (key == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = router.routerDelegate.navigatorKey.currentState;
      if (nav == null) {
        key.fillRange(0, key.length, 0);
        return;
      }
      nav.push(CupertinoPageRoute(
        builder: (_) => ManageInboxIdsPage(linkKey: key),
      ));
    });
  }

  /// A `/publicosAddress/<address>[/<type>[/<key>]]` link for the profile the
  /// user is already looking at switches that Browser's tab in place instead of
  /// stacking a second Browser (a card linking to its own profile round-trips
  /// through the OS and arrives here). A link with a query (`?message=`) still
  /// pushes: the composer pre-fill is only read when a Browser mounts.
  bool _landInVisibleBrowser(String route) {
    final uri = Uri.tryParse(route);
    if (uri == null || uri.query.isNotEmpty) return false;
    final seg = uri.pathSegments;
    if (seg.length < 2 || seg[0] != 'publicosAddress') return false;
    return Browser.landInVisibleBrowser(
      address: seg[1],
      type: seg.length > 2 ? seg[2] : null,
      key: seg.length > 3 ? seg[3] : null,
    );
  }

  /// Returns true if the router's current top-of-stack path matches [route].
  bool _isCurrentRoute(GoRouter router, String route) {
    final currentPath = router.routeInformationProvider.value.uri.path;
    return currentPath == route;
  }

  /// Returns true if [route] is already on screen. Layers on top of
  /// [_isCurrentRoute] with a chat-aware cross-check: a
  /// `/conversationTopic/<topic>` route may be visible under a different URL
  /// shape (DMs are opened in-app as `/inboxId/<inboxId>`), so we also consult
  /// the live conversation tracker.
  bool _isAlreadyVisible(GoRouter router, String route) {
    if (_isCurrentRoute(router, route)) return true;
    final topic = _extractConversationTopic(route);
    if (topic != null &&
        PublicOSConversations.activeConversationTopic == topic) {
      return true;
    }
    return false;
  }

  /// Decodes the topic from a `/conversationTopic/<encodedTopic>` route, or null.
  String? _extractConversationTopic(String route) {
    const prefix = '/conversationTopic/';
    if (!route.startsWith(prefix)) return null;
    return Uri.decodeComponent(route.substring(prefix.length));
  }

  /// Parses a `publicos://` scheme deep link into a GoRouter path.
  String? _parseDeepLinkToRoute(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    if (uri.scheme == 'publicos') {
      final type = uri.host;
      if (type.isEmpty) return null;
      final pathSegments = uri.pathSegments;
      final identifier = pathSegments.isNotEmpty ? pathSegments[0] : null;
      if (identifier == null || identifier.isEmpty) return null;

      // publicos:// is the QR-action family ONLY (profile QR, add_session,
      // new_account). Sharing always uses https://publicos.dev/… with the
      // identifier-class-first shape — those paths pass through verbatim
      // below, so the scheme parser carries no tab/chat/app grammar.
      switch (type) {
        case 'profile':
          return '/publicosAddress/$identifier';
        case 'add_session':
        case 'new_account': {
          // Consent-URI payloads (client_consent_signatures): the
          // `identifier` is a URL-encoded `publicos-claim:<base64>` blob.
          // GoRouter decodes the path-param via `Uri.decodeComponent` at
          // the page builder; we re-encode the SAME path segment to
          // round-trip cleanly through go_router's matcher (which uses /
          // as a delimiter and would otherwise mangle a `+` or `=`).
          return '/$type/${Uri.encodeComponent(identifier)}';
        }
        default:
          return null;
      }
    }

    // Handle https://publicos.dev/... universal links
    if (uri.scheme == 'https' && uri.host == 'publicos.dev') {
      // A shared post, in either shape (a tab link carrying `?post=`, or
      // `/post?url=`), opens the post page, never the tab.
      final link = parse(url);
      if (link?.post != null) return postRouteOf(link!);
      // Return the path as-is — GoRouter's redirect handles normalization
      return uri.path + (uri.query.isNotEmpty ? '?${uri.query}' : '');
    }

    return null;
  }

  /// Run the full init sequence. Updates appState at each step.
  Future<void> initialize() async {
    appState.setLoadingMessage(BootPhase.initializing.name);

    try {
      // Step 1: Initialize core
      final initialized = PublicOS.isInitialized || await PublicOS.initialize();
      if (!initialized) {
        appState.setError(
          BootErr.coreInit,
          onRetry: initialize,
        );
        return;
      }

      appState.setInitialized(true);

      // Resolve module addresses up front — session-independent, and required
      // PRE-login. The new-account / consent-QR flow signs an EIP-712 consent
      // whose verifyingContract = the resolved ACCOUNT_MANAGER. A fresh device
      // never reaches runBoot/initBSP (no session), so without this it stays on
      // the hardcoded fallback and signs against a stale manager address →
      // "Invalid consent signature". resolveModuleAddresses catches its own
      // errors (falls back), so this can't block startup. Idempotent: runBoot's
      // later initBSP re-resolves + does the post-login RPC upgrade.
      await PublicOSBsp.resolveModuleAddresses();
      PublicOSBsp.startPolling();

      await PublicOSConversations.loadDrafts();
      appState.setLoadingMessage(BootPhase.checkingAuth.name);

      // Step 2: Authenticate. A device with a screen lock is asked for it, as
      // always. One without (or one that already has an app PIN) gets the app's
      // own lock screen instead of the dead end it used to hit: that screen
      // sets PublicOS.isAuthenticated and calls initialize again.
      if (!PublicOS.isAuthenticated && !PublicOS.debugNoAuthNeeded) {
        final gate = await PublicOSAuth.authGate();
        if (gate != AuthGate.deviceLock) {
          appState.setLockGate(gate, onRetry: initialize);
          return;
        }
      }
      final isAuthenticated =
          PublicOS.isAuthenticated || await PublicOSAuth.authenticate();
      if (!isAuthenticated && !PublicOS.debugNoAuthNeeded) {
        appState.setError(
          PublicOS.lastError ?? BootErr.authNeeded,
          onRetry: initialize,
        );
        return;
      }

      // Read the auto-login flag BEFORE flipping `authenticated` true. The
      // router redirect fires the instant setAuthenticated(true) notifies, and
      // with no account selected yet it bounces to /select-account — so that
      // screen would flash (and run its loaders) for the whole boot even when
      // auto-login is ON. Raising the pending gate first parks the router on
      // the /init loader until auto-login resolves; the user never sees the
      // select screen while the toggle is on.
      final autoLogin =
          await PublicOS.secureStorage.read(key: 'auto_login') ?? 'false';
      if (autoLogin == 'true') {
        appState.setAutoLoginPending(true);
      }

      appState.setAuthenticated(true);
      appState.setLoadingMessage(BootPhase.checkingLogin.name);

      // Step 3: auto-login. On success runBoot flips accountSelected → home; on
      // failure / no stored account we drop the gate and the redirect falls
      // through to /select-account (silent fallback — never an error screen).
      if (autoLogin == 'true') {
        try {
          await _autoLogin();
        } catch (e) {
          print('Auto-login failed, falling back to account selection: $e');
        } finally {
          appState.setAutoLoginPending(false);
        }
      }
      // If auto-login is false, GoRouter will redirect to /select-account
    } catch (e) {
      print('App initialization error: $e');
      appState.setError(
        BootErr.unexpected,
        onRetry: initialize,
      );
    }
  }

  /// Auto-login on cold start: load the previously-selected account and run
  /// the shared boot sequence. No-op if no account was ever selected.
  Future<void> _autoLogin() async {
    final selectedAccount =
        await PublicOSAccounts.getSelectedAccountAddress();
    if (selectedAccount == null) return;
    await runBoot(selectedAccount, onStatus: appState.setLoadingMessage);
  }

  /// THE single post-account-selection boot sequence. Both entry points feed
  /// it one account: `_autoLogin` (the stored account) and the Select Account
  /// screen (the tapped account). Keeping it in one place is deliberate —
  /// before, each caller held its own copy of these steps and they drifted
  /// (the trailing syncAll lived in only one). Returns true once the account
  /// is fully booted (`setAccountSelected` fired); false if an early stage
  /// fails, so the caller can surface it (a snackbar on the select screen, a
  /// silent return on auto-login).
  ///
  /// [onStatus] receives human-readable progress for whatever loader is
  /// showing (the /init loader's `setLoadingMessage`, or the select screen's
  /// `_setBootStatus`).
  Future<bool> runBoot(
    EthereumAddress account, {
    void Function(String)? onStatus,
  }) async {
    // Stage 1: restore session (load keys, verify session↔account, fetch +
    // save own contact, persist the selected account). Must run before
    // initBSP so myPublicosAddress is set and BSP can resolve the sub.
    onStatus?.call(BootPhase.restoringSession.name);
    final restored = await PublicOSAccounts.restoreSession(account);
    if (!restored) return false;

    // Engine storage boundary: on an engine
    // that cannot partition the webview jar, wipe it when the session changed.
    // Runs here because no webview can exist before boot completes, and a
    // session switch is a cold start.
    await ClientWebStorage.ensureAccountBoundary(
      PublicOS.sessionBlockchainAddress!,
    );

    // Stage 2: BSP (module resolution, RPC upgrade, polling).
    onStatus?.call(BootPhase.connectingChain.name);
    final bspOk = await PublicOS.initBSP();
    if (!bspOk) return false;

    onStatus?.call(BootPhase.loadingKeys.name);
    await AppStateNotifier.loadMyContact();
    await PublicOSKeychain.loadWebSelectedKey(account.eip55With0x);

    // Stage 3: feed server resolution.
    onStatus?.call(BootPhase.connectingFeed.name);
    await PublicOS.initSSP();

    // Stage 4: XMTP client + message stream.
    onStatus?.call(BootPhase.loadingMessages.name);
    await PublicOS.initXMTP();

    // Stage 5: the 15-min Workmanager task runs TWO jobs behind two switches:
    // the chain sweep behind
    // `chain_notifications` (default OFF) and the social inbox pull behind
    // `social_notifications` (default ON). `syncBackgroundTask` is the one
    // place that registers the task (either switch on) or cancels it (both
    // off, which also clears the old always-on worker WorkManager persists
    // across an app update). FCM push (messages + social) is gated separately
    // inside bootstrap on PublicOSSettings.getPushNotifications (default ON).
    // FlutterLocalNotificationsPlugin init already ran inside
    // PublicOS.initialize() (publicos_core.dart::initializeNotifications).
    onStatus?.call(BootPhase.settingUpNotifs.name);
    await PublicOSSettings.syncBackgroundTask();
    await PushNotificationsService.bootstrap();

    // One-time per-account seed of the demo contacts so Discover has people to
    // explore on first launch. Idempotent + best-effort.
    await seedDemoContactsIfNeeded();

    onStatus?.call(BootPhase.opening.name);
    appState.setAccountSelected(true);

    // What this account still has to sign on its server (non-blocking, never
    // fails the boot): the owner's claim on each channel, and posts from
    // before a signature named the post's own address. One isolated block in
    // Core (PublicOSSignatureBacklog); the post half is temporary.
    PublicOSSignatureBacklog.run().catchError((e) {
      print('AppInitializer: [STARTUP] signature backlog failed: $e');
      return (channels: 0, posts: 0, failed: 0);
    });

    // Background sync XMTP conversations (non-blocking).
    print('AppInitializer: [STARTUP] Starting background XMTP sync...');
    PublicOSConversations.syncAll(consentStates: ['allowed', 'unknown']).then((result) {
      print('AppInitializer: [STARTUP] Background sync complete - synced ${result['numGroupsSynced']} conversations');
    }).catchError((e) {
      print('AppInitializer: [STARTUP] Background sync failed: $e');
    });

    return true;
  }

}
