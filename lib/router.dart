import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:publicos_client/app_routes.dart';
import 'package:publicos_client/pages/browser.dart';
import 'package:publicos_client/pages/explorer.dart';
import 'package:publicos_client/components/initialization_screen.dart';
import 'package:publicos_client/components/app_lock_screen.dart';
import 'package:publicos_client/components/select_account_screen.dart';
import 'package:publicos_client/components/add_session_dialog.dart';
import 'package:publicos_client/components/new_account_dialog.dart';
import 'components/feeds/feed_reader_page.dart';
import 'pages/post_from_url_page.dart';
import 'pages/channel_from_url_page.dart';

/// App-wide RouteObserver. Mounted on the GoRouter's `observers:` list so
/// any widget can subscribe (via `RouteAware`) and learn about route
/// pushes/pops above its own route. Used by `Explorer` to refresh tab
/// state (e.g. feeds) when a pushed route (browser, profile QR, system
/// app) pops back.
final RouteObserver<PageRoute<dynamic>> appRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

/// App-wide state notifier that drives GoRouter redirects.
///
/// Tracks initialization, authentication, and account selection phases.
/// Also stores a pending route for deep links that arrive before auth completes.
class AppStateNotifier extends ChangeNotifier {
  /// Singleton instance for access from screens that can't receive it via constructor.
  /// Set in MyAppState.initState, used by SelectAccountScreen after login.
  static AppStateNotifier? instance;

  bool _initialized = false;
  bool _authenticated = false;
  bool _accountSelected = false;
  bool _autoLoginPending = false;
  String? _pendingRoute;
  String? _pendingForAccount;

  /// Fired when a parked route is dropped because another account signed in
  /// (the client shows "Link target not found").
  VoidCallback? onPendingRouteDropped;
  Contact? _myContact;

  /// Subscription to Core's `PublicOS.selfContactUpdates`. Held for the app's
  /// lifetime (the notifier is built once in `main`), cancelled in [dispose].
  StreamSubscription<Contact>? _selfContactSub;

  AppStateNotifier() {
    // Subscribe ONCE: Core emits the signed-in user's fresh Contact here every
    // time `fetchContact` refreshes our own profile (avatar / membership /
    // records). Update the cached snapshot + notify so the bound self-surfaces
    // (explorer app-bar icon, wallet self-card, browser self-header) repaint.
    // Domain-event stream — the event carries the Contact, consumed directly
    // (allowed side of the no-stream-subscriptions rule, like the XMTP stream).
    _selfContactSub = PublicOS.selfContactUpdates.listen((contact) {
      _myContact = contact;
      notifyListeners();
    });
  }

  /// Cached Contact for the currently logged-in account. Loaded after
  /// `restoreSession` via `loadMyContact()`. Replaces the old
  /// `AppStateNotifier.currentMyContact` from Core pre-1.0.
  static Contact? get currentMyContact => instance?._myContact;

  /// Load and cache the current account's Contact. Safe to call multiple times.
  static Future<Contact?> loadMyContact() async {
    final self = instance;
    if (self == null) return null;
    final addrHex = PublicOS.myPublicosAddress;
    if (addrHex == null) {
      self._myContact = null;
      self.notifyListeners();
      return null;
    }
    try {
      final contact =
          await PublicOSContacts.getContact(EthereumAddress.fromHex(addrHex));
      self._myContact = contact;
      self.notifyListeners();
      return contact;
    } catch (_) {
      return self._myContact;
    }
  }

  /// Overwrite the cached contact after an in-app edit (e.g. updating records).
  static void setMyContact(Contact? contact) {
    final self = instance;
    if (self == null) return;
    self._myContact = contact;
    self.notifyListeners();
  }

  // Init phase messages for the loading screen
  String? _loadingMessage;
  String? _errorMessage;
  VoidCallback? _onRetry;

  bool get initialized => _initialized;
  bool get authenticated => _authenticated;
  bool get accountSelected => _accountSelected;
  bool get autoLoginPending => _autoLoginPending;
  String? get pendingRoute => _pendingRoute;
  String? get loadingMessage => _loadingMessage;
  String? get errorMessage => _errorMessage;
  VoidCallback? get onRetry => _onRetry;

  void setInitialized(bool value) {
    _initialized = value;
    notifyListeners();
  }

  void setAuthenticated(bool value) {
    _authenticated = value;
    notifyListeners();
  }

  void setAccountSelected(bool value) {
    _accountSelected = value;
    notifyListeners();
  }

  /// Gate that holds the router on `/init` while a cold-start auto-login is in
  /// flight, so the select-account screen never flashes when the toggle is on.
  /// Raised before `setAuthenticated` in the init sequence; cleared once
  /// auto-login resolves (account booted → home, or failed → select-account).
  void setAutoLoginPending(bool value) {
    _autoLoginPending = value;
    notifyListeners();
  }

  /// [forAccount]: the account a notification popup was for. A deep
  /// link passes none: a link is for whoever signs in.
  void setPendingRoute(String? route, {String? forAccount}) {
    _pendingRoute = route;
    _pendingForAccount = forAccount;
    // No notify — this is read during redirect, not reactive
  }

  /// A `publicos://import_key/<words>/<name>` link (the claim page's QR): the
  /// twelve words and the account's name, held until the select-account screen
  /// takes them. Memory only; taking them clears them.
  ({String words, String name})? _pendingKeyImport;

  void setPendingKeyImport(String words, String name) {
    _pendingKeyImport = (words: words, name: name);
    notifyListeners();
  }

  ({String words, String name})? takePendingKeyImport() {
    final p = _pendingKeyImport;
    _pendingKeyImport = null;
    return p;
  }

  /// A `publicos://link_key/<key>` link (another phone's keychain QR, the key
  /// handoff): the raw key, held until an account is signed in and the Inbox
  /// IDs page takes it. Memory only; taking it clears it, [reset] zeroes it.
  Uint8List? _pendingKeyLink;

  void setPendingKeyLink(Uint8List key) {
    _pendingKeyLink?.fillRange(0, _pendingKeyLink!.length, 0);
    _pendingKeyLink = key;
    notifyListeners();
  }

  Uint8List? takePendingKeyLink() {
    final k = _pendingKeyLink;
    _pendingKeyLink = null;
    return k;
  }

  String? consumePendingRoute() {
    final route = _pendingRoute;
    final forAccount = _pendingForAccount;
    _pendingRoute = null;
    _pendingForAccount = null;
    if (route == null) return null;
    final me = PublicOS.myPublicosAddress;
    if (forAccount != null &&
        me != null &&
        forAccount.toLowerCase() != me.toLowerCase()) {
      onPendingRouteDropped?.call();
      return null;
    }
    return route;
  }

  void setLoadingMessage(String? message) {
    _loadingMessage = message;
    _errorMessage = null;
    _lockGate = null;
    notifyListeners();
  }

  /// Boot is waiting on the app's own lock screen (a device with no screen
  /// lock, or one with an app PIN). `onRetry` re-runs the boot once the
  /// screen is done. Cleared by the next [setLoadingMessage].
  AuthGate? _lockGate;
  AuthGate? get lockGate => _lockGate;

  void setLockGate(AuthGate gate, {VoidCallback? onRetry}) {
    _lockGate = gate;
    _errorMessage = null;
    _onRetry = onRetry;
    notifyListeners();
  }

  void setError(String? error, {VoidCallback? onRetry}) {
    _errorMessage = error;
    _onRetry = onRetry;
    notifyListeners();
  }

  /// Reset to pre-init state (for logout / reset)
  void reset() {
    _initialized = false;
    _authenticated = false;
    _accountSelected = false;
    _autoLoginPending = false;
    _pendingRoute = null;
    _pendingForAccount = null;
    _pendingKeyLink?.fillRange(0, _pendingKeyLink!.length, 0);
    _pendingKeyLink = null;
    _loadingMessage = null;
    _errorMessage = null;
    _lockGate = null;
    _onRetry = null;
    _myContact = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _selfContactSub?.cancel();
    super.dispose();
  }
}

/// Creates the app-wide GoRouter.
///
/// [appState] drives redirect logic for auth gating and deep link deferral.
GoRouter createRouter(AppStateNotifier appState) {
  late final GoRouter router;
  router = GoRouter(
    refreshListenable: appState,
    observers: [appRouteObserver],
    initialLocation: '/init',
    debugLogDiagnostics: true,
    redirect: (context, state) {
      final isInitRoute = state.matchedLocation == '/init';
      final isSelectAccountRoute = state.matchedLocation == '/select-account';

      // Not initialized yet — force to init screen
      if (!appState.initialized || !appState.authenticated) {
        // Store intended route if it's a deep link (not /init or /select-account)
        if (!isInitRoute && !isSelectAccountRoute) {
          appState.setPendingRoute(state.uri.toString());
        }
        return isInitRoute ? null : '/init';
      }

      // Initialized + authenticated but no account selected
      if (!appState.accountSelected) {
        // Auto-login in flight — hold on the /init loader so the select screen
        // never mounts. When it resolves the gate clears: either accountSelected
        // flipped (→ home below) or it failed (→ /select-account next pass).
        if (appState.autoLoginPending) {
          if (!isInitRoute && !isSelectAccountRoute) {
            appState.setPendingRoute(state.uri.toString());
          }
          return isInitRoute ? null : '/init';
        }
        if (!isInitRoute && !isSelectAccountRoute) {
          appState.setPendingRoute(state.uri.toString());
        }
        return isSelectAccountRoute ? null : '/select-account';
      }

      // Fully ready — redirect away from auth screens. A parked route (a
      // notification tap or a deep link on a cold start) is PUSHED on top of
      // home on the next frame instead of being the redirect target: a
      // redirect replaces the stack, and back would then close the app.
      if (isInitRoute || isSelectAccountRoute) {
        final pending = appState.consumePendingRoute();
        if (pending != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => router.push(pending));
        }
        return '/';
      }

      // No redirect needed. (External universal links arrive verbatim —
      // the web URL and the in-app route are the same string by design,
      // so there is no normalizer here.)
      return null;
    },
    routes: [
      // Init screen
      GoRoute(
        path: '/init',
        builder: (context, state) => ListenableBuilder(
          listenable: appState,
          builder: (context, _) => appState.lockGate != null
              ? AppLockScreen(
                  gate: appState.lockGate!,
                  onDone: appState.onRetry ?? () {},
                )
              : InitializationScreen(
                  loadingMessage: appState.loadingMessage,
                  errorMessage: appState.errorMessage,
                  onRetry: appState.onRetry,
                ),
        ),
      ),

      // Account selection
      GoRoute(
        path: '/select-account',
        builder: (context, state) => const SelectAccountScreen(),
      ),

      // Explorer (home)
      GoRoute(
        path: '/',
        pageBuilder: (context, state) => CustomTransitionPage(
          key: state.pageKey,
          child: const Explorer(),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      ),

      // Account family — /publicosAddress/:address[/:type[/:key]].
      // The first segment is the ContactIdentifierType name verbatim; web
      // URLs and in-app routes are the same string. :type is the closed
      // vocabulary {profile, settings, management, tab, chat, app}; :key is
      // the record key (tab), inbox label (chat), or app name (app).
      // Resolution happens in the Browser against the loaded contact.
      GoRoute(
        path: '/publicosAddress/:address',
        pageBuilder: (context, state) => _browserPage(
          state: state,
          identifierType: ContactIdentifierType.publicosAddress,
          identifier: state.pathParameters['address']!,
        ),
        routes: [
          GoRoute(
            path: ':type',
            pageBuilder: (context, state) => _browserPage(
              state: state,
              identifierType: ContactIdentifierType.publicosAddress,
              identifier: state.pathParameters['address']!,
              routeType: state.pathParameters['type'],
            ),
            routes: [
              GoRoute(
                path: ':key',
                pageBuilder: (context, state) => _browserPage(
                  state: state,
                  identifierType: ContactIdentifierType.publicosAddress,
                  identifier: state.pathParameters['address']!,
                  routeType: state.pathParameters['type'],
                  routeKey: state.pathParameters['key'],
                  // In-app deep links carry the destination Record/AppBookmark
                  // here (go_router `extra`); cold/external links are null.
                  landingPayload: state.extra,
                  // `?message=` pre-fills the chat composer (compose-to-contact,
                  // e.g. Quests "claim <id>"); pre-fill only, never auto-sends.
                  messageDraft: state.uri.queryParameters['message'],
                ),
              ),
            ],
          ),
        ],
      ),

      // Group chat (by conversation topic, percent-encoded in the path)
      GoRoute(
        path: '/conversationTopic/:topic',
        pageBuilder: (context, state) => _browserPage(
          state: state,
          identifierType: ContactIdentifierType.xmtpConversationTopic,
          identifier: Uri.decodeComponent(state.pathParameters['topic']!),
        ),
      ),

      // Add session (deep link from QR). `:payload` is the full
      // `publicos-claim:<base64-cbor>` URI scanned from the new device.
      GoRoute(
        path: '/add_session/:payload',
        pageBuilder: (context, state) => DialogPage(
          key: state.pageKey,
          child: AddSessionDialog(
            payload: Uri.decodeComponent(state.pathParameters['payload']!),
          ),
        ),
      ),

      // New account (deep link from QR). `:payload` is the full
      // `publicos-claim:<base64-cbor>` URI scanned from the new device.
      GoRoute(
        path: '/new_account/:payload',
        pageBuilder: (context, state) => DialogPage(
          key: state.pageKey,
          child: NewAccountDialog(
            payload: Uri.decodeComponent(state.pathParameters['payload']!),
          ),
        ),
      ),

      // A post by permalink: the tap on a social notification
      // (`post:<item_url>`). The URL rides as a
      // query parameter so its slashes never meet the path matcher.
      GoRoute(
        path: '/post',
        pageBuilder: (context, state) => CupertinoPage<void>(
          key: state.pageKey,
          child: PostFromUrlPage(
            url: state.uri.queryParameters['url'] ?? '',
            // A share link's extras; a notification tap carries the url alone.
            feed: state.uri.queryParameters['feed'],
            foundAt: state.uri.queryParameters['at'],
            tabKey: state.uri.queryParameters['tab'],
            ladder: state.uri.queryParameters['link'] == '1',
          ),
        ),
      ),

      // One feed by URL, ours or an outside one: the page a shared post puts
      // under itself when its tab does not verify. App-internal: not a
      // publicos.dev shape, never shared.
      GoRoute(
        path: '/feed',
        pageBuilder: (context, state) => CupertinoPage<void>(
          key: state.pageKey,
          child: FeedReaderPage(
            feedUrl: state.uri.queryParameters['url'] ?? '',
            title: state.uri.queryParameters['title'],
          ),
        ),
      ),

      // A channel by URL, two doors (the taps on the two follow kinds):
      // `/channel-requests` = the owner's settings on the request queue,
      // `/channel` = the channel's feed. App-internal like `/post`: neither is
      // a publicos.dev shape, the web page's link families are untouched.
      GoRoute(
        path: '/channel-requests',
        pageBuilder: (context, state) => CupertinoPage<void>(
          key: state.pageKey,
          child: ChannelFromUrlPage(
            url: state.uri.queryParameters['url'] ?? '',
            requests: true,
          ),
        ),
      ),
      GoRoute(
        path: '/channel',
        pageBuilder: (context, state) => CupertinoPage<void>(
          key: state.pageKey,
          child: ChannelFromUrlPage(
            url: state.uri.queryParameters['url'] ?? '',
            requests: false,
          ),
        ),
      ),

      // Chat (by XMTP inbox ID — the direct pointer; dies if the inbox is
      // abandoned. The durable alias is /publicosAddress/:address/chat/:label.)
      GoRoute(
        path: '/inboxId/:inboxId',
        pageBuilder: (context, state) => _browserPage(
          state: state,
          identifierType: ContactIdentifierType.xmtpInboxId,
          identifier: state.pathParameters['inboxId']!,
          inboxId: state.pathParameters['inboxId'],
        ),
      ),
    ],
  );
  return router;
}

/// Builds a CupertinoPage for Browser routes.
/// CupertinoPage uses CupertinoPageRoute which supports native iOS swipe-back.
CupertinoPage<void> _browserPage({
  required GoRouterState state,
  required ContactIdentifierType identifierType,
  required String identifier,
  String? routeType,
  String? routeKey,
  String? inboxId,
  Object? landingPayload,
  String? messageDraft,
}) {
  return CupertinoPage<void>(
    key: state.pageKey,
    child: Browser(
      identifierType: identifierType,
      identifier: identifier,
      routeType: routeType,
      routeKey: routeKey,
      inboxId: inboxId,
      landingPayload: landingPayload,
      messageDraft: messageDraft,
    ),
  );
}

/// A Page subclass that displays its child as a dialog overlay.
/// Used for routes like /add_session that should appear as modal dialogs.
class DialogPage extends Page<void> {
  final Widget child;

  const DialogPage({super.key, required this.child});

  @override
  Route<void> createRoute(BuildContext context) {
    return DialogRoute(
      context: context,
      settings: this,
      builder: (context) => child,
    );
  }
}
