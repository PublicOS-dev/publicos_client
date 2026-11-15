import 'dart:async';
import 'package:publicos_core/publicos_core.dart';
import 'dart:io' show Platform;
import 'dart:typed_data' show Uint8List;
import 'package:zero_cached_image/zero_cached_image.dart' show ZeroFetchHooks;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';
import 'ios/ios_app_group.dart';
import 'providers/theme_provider.dart';
import 'providers/locale_provider.dart';
import 'l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'router.dart';
import 'app_initializer.dart';
import 'push_notifications_service.dart';
import 'utils/notification_kinds.dart';
import 'utils/own_wallets.dart';
import 'utils/social_notifs.dart';

/// Background task callback dispatcher - must be top-level function
@pragma('vm:entry-point')
void callbackDispatcher() {

  Workmanager().executeTask((task, inputData) async {
    print('Workmanager: Executing background task: $task');
    return await runChainNotificationSync();
  });
  
}

/// The 15-min Workmanager body: ONE worker, TWO jobs, TWO switches.
/// There is no XMTP message sweep here — FCM push is the message path.
///
/// Job 1, behind `chain_notifications` (default OFF): the read-only chain
/// sweep, two readers that are deliberately independent:
///   * [PublicOSActivity]      — contract events (vouch / citizenship / domain /
///                               profile), scoped to the user's CONTACTS.
///   * [PublicOSWalletActivity] — token transfers, scoped to the user's OWN
///                               WALLETS (personal main Safe + org main Safes +
///                               `walletEnabled` keychain EOAs).
/// Job 2, behind `social_notifications` (default ON): the SIGNED pull of the
/// account's inbox at its HOME SSP (replies, comments, mentions, reactions,
/// follow requests), the backstop for a social push that never arrived.
///
/// A failing job must not suppress the other's popups, so each runs in its
/// own try/catch and the results are merged before the taxonomy runs. The
/// task is registered when either switch is on (`PublicOSSettings
/// .syncBackgroundTask`); inside, each job checks its own switch. Filtering
/// uses the SAME client taxonomy as the in-app feed (`buildNotifications`),
/// so the per-type toggles + 24h throttle apply to popups too. Best-effort:
/// never throws out of the task.
@pragma('vm:entry-point')
Future<bool> runChainNotificationSync() async {
  try {
    // Skip while the app is foreground — the explorer's in-app sweeps already
    // refresh the feed/badge; an OS popup would double up. The bg isolate's
    // statics are blank, so read the cross-isolate prefs flag, not isForeground.
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('app_in_foreground') == true) return true;

    final sessionAddr = await PublicOSActivity.ensureChainIsolateReady();
    if (sessionAddr == null) return true; // no selected account / keys yet

    final chainOn = await PublicOSSettings.getChainNotifications();
    final socialOn = await PublicOSSettings.getSocialNotifications();
    final fresh = <ActivityEvent>[];
    final ownWallets = <OwnWallet>[];

    if (chainOn) {
      // 1. Contract events (contact-scoped).
      try {
        fresh.addAll(await PublicOSActivity.sweepCollectingNew());
      } catch (_) {/* a failed contract sweep must not kill the wallet popups */}

      // 2. Token transfers (own-wallet-scoped). The watched set is enumerated
      //    CLIENT-side and handed to Core — `walletEnabled` is a UI toggle, so
      //    "which wallets do I watch" is client policy, not a chain fact.
      //    ensureChainIsolateReady() brought up web3 + the module registry +
      //    secure storage AND set `myPublicosAddress`; without it the wallet
      //    half cannot run in the background.
      try {
        final me = PublicOS.myPublicosAddress;
        if (me != null) {
          ownWallets.addAll(
              await loadOwnReceivingWallets(EthereumAddress.fromHex(me)));
          if (ownWallets.isNotEmpty) {
            fresh.addAll(await PublicOSWalletActivity.sweepCollectingNew(
              wallets: ownWallets
                  .map((w) => EthereumAddress.fromHex(w.address))
                  .toList(growable: false),
            ));
          }
        }
      } catch (_) {/* likewise — a failed wallet sweep must not kill the rest */}
    }

    if (socialOn) {
      // 3. The home inbox, signed by the session key the isolate restored.
      //    The home URL is resolved as the main app does (cached active SSP,
      //    else slugOf → registry apiUrl); no home → skip this tick.
      try {
        final me = PublicOS.myPublicosAddress;
        final home = await PublicOSSsp.homeForIsolate();
        if (me != null && home != null) {
          fresh.addAll(await pullSocialInbox(account: me, home: home));
        }
      } catch (_) {/* a failed pull must not kill the chain popups */}
    }

    if (fresh.isEmpty) return true;

    // The readers return newest-first each, but MERGING them interleaves the
    // orders — re-sort globally so the 24h throttle keeps the most-recent row
    // of a burst and the take(8) cap below keeps the newest events overall.
    // Social rows carry no block (0), so the sort is by time first.
    fresh.sort((a, b) {
      final c = b.timestamp.compareTo(a.timestamp);
      if (c != 0) return c;
      final d = b.blockNumber.compareTo(a.blockNumber);
      return d != 0 ? d : b.logIndex.compareTo(a.logIndex);
    });
    final enabled = await loadEnabledNotifKinds();
    final items = buildNotifications(fresh, enabled); // filter + 24h throttle
    if (items.isEmpty) return true;

    // Resolve actor display names from the local contact cache.
    final contacts = await PublicOSContacts.getStoredContacts();
    final byAddr = <String, Contact>{};
    for (final c in contacts) {
      final a = c.publicosAddress?.eip55With0x.toLowerCase();
      if (a != null) byAddr[a] = c;
    }
    final selfLower = sessionAddr.toLowerCase();
    bool isSelf(String a) => a.toLowerCase() == selfLower;
    String nameOf(String a) {
      if (isSelf(a)) return 'You';
      final c = byAddr[a.toLowerCase()];
      final n = c?.publicosDisplayName ?? c?.displayName;
      if (n != null && n.trim().isNotEmpty) return n.trim();
      return a.length > 10
          ? '${a.substring(0, 6)}…${a.substring(a.length - 4)}'
          : a;
    }

    // Wallet rows name WALLETS ("main", the org's name, the key's label), which
    // are Safe/EOA addresses and so never appear in the contact map above.
    final walletNames = <String, String>{
      for (final w in ownWallets) w.address.toLowerCase(): w.name,
    };
    String? walletNameOf(String a) => walletNames[a.toLowerCase()];

    // The counterparty is named via the ACCOUNT Core reverse-resolved from their
    // wallet at sweep time — a Safe address is never a contact address.
    //
    // Local contacts ONLY here. The notifications screen falls back to
    // `fetchContact` for an unknown account, but that is 4-7 chain calls and
    // this is a background isolate on a 15-min timer: an unknown sender simply
    // goes unnamed ("Received 5 OX in main"), which reads fine.
    final cpByWallet = <String, Contact>{};
    for (final item in items) {
      if (!kWalletKinds.contains(item.kind)) continue;
      final w = transferCounterpartyWallet(item.event);
      final acct = transferCounterpartyAccount(item.event);
      if (w == null || acct == null) continue;
      final c = byAddr[acct.toLowerCase()];
      if (c != null) cpByWallet[w.toLowerCase()] = c;
    }
    String? counterpartyNameOf(String walletHex) {
      final c = cpByWallet[walletHex.toLowerCase()];
      final n = c?.publicosDisplayName ?? c?.displayName;
      return (n != null && n.trim().isNotEmpty) ? n.trim() : null;
    }

    // Cap per sweep — the cold-start cursor seed already prevents history
    // dumps; this just bounds a genuinely busy window. items is newest-first,
    // so the most recent events win the cap.
    final l10n = await isolateLocalizations();
    for (final item in items.take(8)) {
      // A social row quotes the real text, fetched from its host.
      final body = withSocialPreview(
        notifSentence(
          item,
          l10n,
          isSelf: isSelf,
          nameOf: nameOf,
          walletNameOf: walletNameOf,
          counterpartyNameOf: counterpartyNameOf,
        ),
        await socialPreview(item),
      );
      final id =
          '${item.event.txHash}:${item.event.logIndex}'.hashCode & 0x7fffffff;
      await PublicOSActivity.showActivityNotification(
        id: id,
        title: 'PublicOS',
        body: body,
        // A social popup opens its post, a money popup the wallet, the rest
        // the feed.
        payload: activityTapPayload(item),
      );
    }
    // Release this isolate's DB connection (same file the main app holds open;
    // mirrors the message sweep's close-on-success) before the isolate dies.
    await PublicOS.database.close();
    return true;
  } catch (_) {
    // Background best-effort — a failure must not crash the Workmanager task.
    return true;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final bool isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  // iOS App Group setup — relocates XMTP DB + drift DB + avatar cache into
  // the shared container, mirrors the XMTP DB key into shared Keychain, and
  // wires `PublicOS.onXmtpClientReady` to publish `active_xmtp.json` so the
  // Notification Service Extension can decrypt incoming pushes. Must run
  // BEFORE PublicOS.initialize() (which constructs AppDatabase) and before
  // any ZeroCacheManager usage. No-op on non-iOS.
  if (isMobile && Platform.isIOS) {
    await IosAppGroup.setup();
  }

  // Firebase Core boot (gates FCM push notification delivery).
  // Web is intentionally excluded — FCM web-push uses service workers,
  // a different shape than firebase_messaging on Android/iOS.
  if (isMobile) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    // Register the top-level background message handler before any
    // FCM event can arrive. Foreground handler is wired by
    // PushNotificationsService after the runtime app starts.
    FirebaseMessaging.onBackgroundMessage(firebasePushBackgroundHandler);

    // Every time an XMTP key becomes the loaded one (boot or any screen that
    // loads a key), register that installation for message pushes. The hook
    // has one slot and iOS already uses it (IosAppGroup.setup above), so
    // keep what is there.
    final onReady = PublicOS.onXmtpClientReady;
    PublicOS.onXmtpClientReady = () {
      onReady?.call();
      unawaited(PushNotificationsService.onXmtpKeyLoaded());
    };
  }

  // Workmanager engine for the 15-min "Chain notifications" sweep
  // (callbackDispatcher → runChainNotificationSync). The periodic task is only
  // REGISTERED when the user enables chain notifications (AppInitializer);
  // initializing the engine here is cheap and required before any registration.
  if (isMobile) {
    await Workmanager().initialize(
      callbackDispatcher,
    );
  }

  // Increase image cache limits for smoother scrolling
  PaintingBinding.instance.imageCache.maximumSize = 500; // 500 images
  PaintingBinding.instance.imageCache.maximumSizeBytes = 100 << 20; // 100 MB

  // Private-media fetch hooks.
  // The zero packages (image + video share one downloader) know nothing about
  // PublicOS; these two callbacks teach them the envelope challenge protocol:
  // a gated URL answers 401 + WWW-Authenticate → requestAuth signs a
  // pedia_read envelope to exactly that URL and the fetch retries once; a
  // response marked X-Publicos-Sealed is ECIES ciphertext → responseTransform
  // decrypts it before caching (cache holds plaintext — the device keychain
  // lives on this storage anyway). Public URLs never challenge and never
  // carry the header, so they take today's path untouched.
  if (!kIsWeb) {
    ZeroFetchHooks.requestAuth = (url) async => PublicOSSsp.pediaRequestAuth(url);
    ZeroFetchHooks.responseTransform = (bytes, headers) async =>
        PublicOSSsp.pediaResponseTransform(
            bytes is Uint8List ? bytes : Uint8List.fromList(bytes), headers);
  }

  // Framework errors (the red screen) into the in-app log too, so a shared
  // log carries the FIRST error, not just what happened around it.
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    Log.e('Flutter', '${details.exceptionAsString()}\n${details.stack ?? ''}');
    previousOnError?.call(details);
  };

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final ThemeProvider _themeProvider = ThemeProvider();
  final LocaleProvider _localeProvider = LocaleProvider();
  late final AppStateNotifier _appState;
  late final AppInitializer _initializer;
  late final GoRouter router;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _themeProvider.addListener(_onThemeChanged);
    _localeProvider.addListener(_onLocaleChanged);
    LocaleProvider.instance = _localeProvider;

    _appState = AppStateNotifier();
    AppStateNotifier.instance = _appState;
    router = createRouter(_appState);
    _initializer = AppInitializer(_appState);
    _initializer.setupDeepLinkChannel(router);
    _initializer.initialize();
    PublicOS.setForeground(true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _themeProvider.removeListener(_onThemeChanged);
    _localeProvider.removeListener(_onLocaleChanged);
    _appState.dispose();
    PublicOS.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      PublicOS.setForeground(true);
      _resumeXmtp();
      _pullSocialOnResume();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      PublicOS.setForeground(false);
    }
  }

  bool _xmtpRetrying = false;

  /// Resume: the home inbox, so a push the OS dropped shows within seconds
  /// of coming back instead of at the next 15-min tick. Gated like XMTP.
  Future<void> _pullSocialOnResume() async {
    if (!PublicOS.isAuthenticated || !_appState.accountSelected) return;
    await pullSocialInboxNow();
  }

  /// Resume: restart the message stream, or — if boot's Stage 4 left XMTP
  /// down (e.g. a cold start after Android killed us in the background) —
  /// retry the whole client init. initXMTP never registers a new installation
  /// (it bails unless the stored key is `ready`) and starts the stream itself.
  /// Gated on accountSelected so it never races runBoot's own Stage 4.
  Future<void> _resumeXmtp() async {
    if (!PublicOS.isAuthenticated || !_appState.accountSelected) return;
    if (_xmtpRetrying) return;
    _xmtpRetrying = true;
    try {
      if (!PublicOS.xmtpConnected) {
        await PublicOS.initXMTP();
      } else if (PublicOS.clientXmtpInboxId != null) {
        await PublicOSConversations.initializeMessages();
      }
    } catch (e) {
      print('XMTP resume failed: $e');
    } finally {
      _xmtpRetrying = false;
    }
  }

  void _onThemeChanged() {
    setState(() {});
  }

  void _onLocaleChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isDark = _themeProvider.isDarkMode;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: isDark ? _themeProvider.getDarkTheme().scaffoldBackgroundColor : _themeProvider.getLightTheme().scaffoldBackgroundColor,
        systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      ),
      child: MaterialApp.router(
        title: 'PublicOS',
        debugShowCheckedModeBanner: false,
        theme: _themeProvider.getLightTheme(),
        darkTheme: _themeProvider.getDarkTheme(),
        themeMode: _themeProvider.themeMode,
        locale: _localeProvider.locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    );
  }
}
