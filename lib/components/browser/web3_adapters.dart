// The four seams that connect `publicos_web3_bridge` to THIS app.
//
// The bridge owns the EIP-1193 protocol, the grant gate and every line that
// touches a key. It deliberately knows nothing about `webview_flutter`,
// `PublicOS_Core`, GoRouter or bottom sheets -- those are the four places the
// two clients genuinely differ, so each is an interface there and an
// implementation here.
//
// Desktop will have its own copy of this file, and nothing else.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:publicos_core/publicos_core.dart';
import 'package:publicos_web3_bridge/publicos_web3_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web3dart/web3dart.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'package:publicos_client/components/browser/connect_request_sheet.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/router.dart'; // AppStateNotifier
import 'package:publicos_client/components/browser/signature_request_sheet.dart';

/// [WebViewHost] over `webview_flutter`.
///
/// Thin on purpose: it converts one vocabulary into another and holds no
/// policy. Every judgement lives above it, in the bridge.
class WebViewFlutterHost implements WebViewHost {
  final WebViewController controller;

  final _events = StreamController<WebViewEvent>.broadcast();
  final _messages = StreamController<String>.broadcast();

  WebViewFlutterHost(this.controller);

  /// The single JS channel the provider posts on. The name is part of the
  /// injected script's contract -- see `BridgeTransport.javaScriptChannel`.
  static const String channelName = 'FlutterWeb3';

  /// Feed lifecycle in from the controller's NavigationDelegate, which the
  /// widget owns because it also drives its own chrome from those callbacks.
  void emitEvent(WebViewEvent event) => _events.add(event);

  /// Feed a raw page message in from the JavaScript channel.
  void emitMessage(String json) => _messages.add(json);

  @override
  Stream<WebViewEvent> get events => _events.stream;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> load(Uri url) => controller.loadRequest(url);

  @override
  Future<void> runJavaScript(String js) => controller.runJavaScript(js);

  @override
  Future<Object?> evaluate(String js) =>
      controller.runJavaScriptReturningResult(js);

  /// ⚠️ **Not actually document-start on this engine.**
  ///
  /// `webview_flutter` exposes neither Android's `addDocumentStartJavaScript`
  /// nor iOS's `WKUserScript`, so the closest available moment is page-finish
  /// -- which is what the widget does, by calling the bridge's injector from
  /// its `onPageFinished`. Running it here would inject into the OUTGOING
  /// document, which is worse than late.
  ///
  /// [supportsDocumentStartInjection] reports `false` so nothing upstream
  /// believes otherwise. WebView2 on desktop does this properly.
  @override
  Future<void> injectAtDocumentStart(String js) async {}

  @override
  bool get supportsDocumentStartInjection => false;

  @override
  Future<void> postMessage(String json) =>
      controller.runJavaScript('window.FlutterWeb3Bridge && '
          'window.FlutterWeb3Bridge.resolveRequest($json);');

  @override
  Future<void> goBack() => controller.goBack();

  @override
  Future<bool> canGoBack() => controller.canGoBack();

  @override
  Future<void> dispose() async {
    await _events.close();
    await _messages.close();
  }
}

/// [Web3Consent] over this app's bottom sheets.
///
/// **Defaults to refusal in every direction**, which is the contract: an
/// unmounted context, a dismissed sheet and a thrown route all mean no.
/// Silence is never consent.
///
/// Note the asymmetry the set model forces: a connect refusal is `null`, not
/// an empty set -- the empty set is a real user decision (disconnect every key)
/// and `ConnectGate` applies it as one.
class SheetWeb3Consent implements Web3Consent {
  /// Read fresh on every ask rather than captured, because a sheet may be
  /// raised long after construction and the element may be gone by then.
  final BuildContext? Function() contextOf;

  final String Function() chainIdOf;

  const SheetWeb3Consent({required this.contextOf, required this.chainIdOf});

  @override
  Future<ConnectDecision?> requestConnect(ConnectRequest request) async {
    final context = contextOf();
    if (context == null || !context.mounted) return null;
    try {
      return await ConnectRequestSheet.show(
        context: context,
        // The ORIGIN, not the page URL. `request.origin` is the live document
        // URL, so `.toString()` carried the path and query -- a four-line
        // `https://app.zerion.io/send?inputFungibleId=0x...` in a header built
        // for one. It was also a quiet lie: the grant is recorded against
        // `originKey`, so the string the user is asked to approve must be the
        // string that gets stored.
        origin: ConnectGate.originKey(request.origin),
        keys: request.keys,
        alreadyGranted: request.alreadyGranted,
        preferred: request.preferred,
        requested: request.requested,
        activeKey: request.activeKey,
        sessionKeyName: sessionKeyName(context),
        currentChainId: chainIdOf(),
      );
    } catch (_) {
      return null;
    }
  }

  /// The session key's display name -- the account's own, since "Session Key" is
  /// what the key IS, not what the user calls themselves. Resolved here rather
  /// than in the picker so the sheet stays a dumb renderer of what it is given.
  static String sessionKeyName(BuildContext context) =>
      AppStateNotifier.currentMyContact?.displayName ??
      context.l10n.connectRequestSheetSessionKey;


  @override
  Future<bool> requestSignature(SignatureRequest request) async {
    final context = contextOf();
    if (context == null || !context.mounted) return false;
    try {
      return await SignatureRequestSheet.show(
        context: context,
        requestType: _sheetType(request.kind),
        message: request.kind == SignatureKind.message ||
                request.kind == SignatureKind.legacyEthSign
            ? request.display
            : null,
        transactionData: request.kind == SignatureKind.transaction ||
                request.kind == SignatureKind.sendTransaction
            ? request.payload as Map<String, dynamic>?
            : null,
        typedData:
            request.kind == SignatureKind.typedData ? request.payload : null,
        // Same rule as the connect sheet: show the origin the permission is
        // scoped to, not the page's full URL.
        requestingOrigin: ConnectGate.originKey(request.origin),
        currentChainId: chainIdOf(),
        // The address the dApp named and the gate approved. The sheet shows
        // exactly this and offers no switcher -- what is displayed is what
        // signs.
        signingAddress: request.address,
      );
    } catch (_) {
      return false;
    }
  }

  /// The mapping is 1:1 and must stay that way. `eth_sign` in particular has
  /// its own case because the sheet warns harder about blind signing.
  static SignatureRequestType _sheetType(SignatureKind kind) => switch (kind) {
        SignatureKind.message => SignatureRequestType.personalSign,
        SignatureKind.legacyEthSign => SignatureRequestType.ethSign,
        SignatureKind.typedData => SignatureRequestType.signTypedData,
        SignatureKind.transaction => SignatureRequestType.signTransaction,
        SignatureKind.sendTransaction => SignatureRequestType.sendTransaction,
      };
}

/// [WalletBinding] over Core's keychain.
///
/// Answers three questions the bridge asks and NOTHING else: which keys exist,
/// which one is preferred, and what signs for a given address. A host-pinned
/// wallet (the "Manage" flow) short-circuits all three.
///
/// ── NO FALLBACK. ANYWHERE. ───────────────────────────────────────────────────
/// [signingKeyFor] is an EXACT match or null, and that is the point of the
/// class. A trailing
/// `?? PublicOS.currentBlockchainPrivateKey` would make a lookup that missed sign as
/// the session key instead -- producing a signature that does not recover to the
/// address the page was shown. Core's own helpers have no such
/// substitution either; do not introduce it at either
/// layer.
class SessionWalletBinding implements WalletBinding {
  /// Set by the wallet-manager sheet to pin this webview to one wallet.
  ///
  /// **Closures, not values, and that is load-bearing.** The wallet manager
  /// does NOT wait for the key before building the webview: it kicks off
  /// `exportPrivateKey` in `initState` and renders immediately, so the first
  /// build passes `null` and the real key arrives a frame or two later via
  /// `setState`.
  ///
  /// Holding the value would freeze that `null` for the life of the bridge, and
  /// every signature would silently fall back to the keychain -- the page would
  /// be told one address and sign with another, which is the exact failure this
  /// class exists to prevent. Reading through a closure restores the late
  /// binding the pre-refactor code had by reading `widget.overrideSigningKey`
  /// on every call.
  final String? Function() overrideAccountAddressOf;
  final EthPrivateKey? Function() overrideSigningKeyOf;

  /// The logged-in account, whose keychain this reads.
  final String? Function() userAddressOf;

  const SessionWalletBinding({
    required this.userAddressOf,
    required this.overrideAccountAddressOf,
    required this.overrideSigningKeyOf,
  });

  /// A pinned view offers exactly one key -- the wallet the user pressed
  /// "Manage" on. A manager for one wallet forces that wallet: there is nothing
  /// to pick, so the picker gets one row and [signingKeyFor] refuses every
  /// other address rather than reaching into a keychain this view is not
  /// speaking for.
  PinnedWalletBinding? get _pin {
    final address = overrideAccountAddressOf();
    if (address == null || address.isEmpty) return null;
    return PinnedWalletBinding(
      address: address,
      signingKey: overrideSigningKeyOf(),
    );
  }

  @override
  Future<List<WalletKey>> availableKeys() async {
    final pin = _pin;
    if (pin != null) return pin.availableKeys();

    // The session key is NOT in `fetchKeys` -- that walks the keychain index
    // only -- so it is prepended here. It is deliberately FIRST: it is the
    // account's own identity and the default `accounts[0]` when no preference
    // applies. `fetchKeys` sorts the rest alphabetically by label.
    final session = PublicOS.sessionBlockchainAddress;
    final user = userAddressOf();
    final keys = <WalletKey>[
      if (session != null && session.isNotEmpty)
        WalletKey(label: 'session', address: session),
    ];
    if (user == null) return keys;

    try {
      for (final k in await PublicOSKeychain.fetchKeys(user)) {
        final address = (k['address'] ?? '') as String;
        if (address.isEmpty || address == 'Unknown') continue;
        keys.add(WalletKey(
          label: k['label'] as String,
          address: address,
          emoji: k['emoji'] as String?,
        ));
      }
    } catch (e) {
      debugPrint('[web3] could not load keychain keys: $e');
    }
    return keys;
  }

  @override
  Future<String?> preferredAddress() async {
    final pin = _pin;
    if (pin != null) return pin.preferredAddress();

    final user = userAddressOf();
    if (user == null) return PublicOS.sessionBlockchainAddress?.toLowerCase();
    // Null when the pointer names a key that no longer exists. That is a
    // missing PREFERENCE, not a missing identity: ordering falls back to
    // keychain order, and nothing is granted or signed differently.
    final addr = await PublicOSKeychain.getWebSelectedAddress(user);
    return (addr == null || addr.isEmpty) ? null : addr.toLowerCase();
  }

  @override
  Future<EthPrivateKey?> signingKeyFor(String address) async {
    final pin = _pin;
    if (pin != null) return pin.signingKeyFor(address);

    final wanted = address.toLowerCase();

    // The session key is not in the keychain, so it is matched first, and by
    // ADDRESS -- never by the label a grant happens to carry, which is
    // display-only and survives a rename.
    final sessionKey = PublicOS.currentBlockchainPrivateKey;
    if (sessionKey != null &&
        sessionKey.address.eip55With0x.toLowerCase() == wanted) {
      return sessionKey;
    }

    final user = userAddressOf();
    if (user == null) return null;
    try {
      for (final k in await PublicOSKeychain.fetchKeys(user)) {
        if (((k['address'] ?? '') as String).toLowerCase() != wanted) continue;
        final hex = k['privateKey'] as String?;
        if (hex == null || hex.isEmpty || hex == 'Error loading key') return null;
        return EthPrivateKey.fromHex(hex);
      }
    } catch (e) {
      debugPrint('[web3] could not resolve signing key: $e');
    }
    return null;
  }
}

/// [GrantStore] over Core's database.
///
/// Three calls, no logic. The table itself is Core's; what a grant MEANS is
/// the bridge's.
class CoreGrantStore implements GrantStore {
  const CoreGrantStore();

  @override
  Future<bool> hasGrant({
    required String origin,
    required String session,
    required String eoa,
  }) =>
      PublicOS.database.hasGrant(origin: origin, session: session, eoa: eoa);

  @override
  Future<List<String>> listGrants({
    required String origin,
    required String session,
  }) =>
      PublicOS.database.listGrantsForOrigin(origin: origin, session: session);

  @override
  Future<void> grantSite({
    required String origin,
    required String session,
    required String eoa,
    String? keyLabel,
  }) =>
      PublicOS.database.grantSite(
        origin: origin,
        session: session,
        eoa: eoa,
        keyLabel: keyLabel,
      );

  @override
  Future<void> revokeSite({
    required String origin,
    required String session,
    required String eoa,
  }) =>
      PublicOS.database.revokeSite(origin: origin, session: session, eoa: eoa);

  @override
  Future<void> touchGrant({
    required String origin,
    required String session,
    required String eoa,
  }) =>
      PublicOS.database.touchGrant(origin: origin, session: session, eoa: eoa);

  @override
  Future<String?> activeKeyFor({
    required String origin,
    required String session,
  }) =>
      PublicOS.database.siteActiveKey(origin: origin, session: session);

  @override
  Future<void> setActiveKey({
    required String origin,
    required String session,
    required String eoa,
  }) =>
      PublicOS.database
          .setSiteActiveKey(origin: origin, session: session, eoa: eoa);

  @override
  Future<void> clearActiveKey({
    required String origin,
    required String session,
  }) =>
      PublicOS.database.clearSiteActiveKey(origin: origin, session: session);
}

/// [WebStorageProfile] over `webview_flutter` -- the fifth seam.
///
/// Android binds a profile at construction (our fork of
/// `webview_flutter_android`), WebKit takes a data store on the configuration
/// (our fork of `webview_flutter_wkwebview`). Web gets the plain controller:
/// out of scope, the browser owns storage there.
///
/// Both forks are permanent path overrides (`pubspec.yaml`); the package
/// names are upstream's because `webview_flutter` resolves them by name.
class ClientWebStorage implements WebStorageProfile<WebViewController> {
  const ClientWebStorage();

  @override
  Future<bool> get isolates async {
    if (kIsWeb) return false;
    if (Platform.isAndroid) {
      // The one engine that may say no: WebView < 121 has no MULTI_PROFILE.
      return AndroidWebViewController.isMultiProfileSupported();
    }
    // WebKit isolates either way -- a persistent per-identifier store on
    // iOS 17+, an in-memory one below. Both are this profile's alone.
    return true;
  }

  @override
  Future<WebViewController> createController(String profileId) async {
    if (kIsWeb) return WebViewController();

    if (Platform.isAndroid) {
      if (!await isolates) {
        // Shared jar. The boot guard (ensureAccountBoundary) has already
        // wiped it if the session changed; nothing else to do here.
        return WebViewController();
      }
      return WebViewController.fromPlatformCreationParams(
        AndroidWebViewControllerCreationParams(profileName: profileId),
      );
    }

    if (Platform.isIOS) {
      WKWebsiteDataStore store;
      try {
        store = await WKWebsiteDataStore.dataStoreForIdentifier(
          WebStorageProfileId.uuidFor(profileId),
        );
      } on PlatformException catch (e) {
        // iOS 15-16: no named persistent stores. Isolated for the run, gone
        // at exit. Any OTHER failure is a real one and stays loud.
        if (e.code != 'FWFUnsupportedVersionError') rethrow;
        store = await WKWebsiteDataStore.nonPersistentDataStore();
      }
      return WebViewController.fromPlatformCreationParams(
        WebKitWebViewControllerCreationParams(websiteDataStore: store),
      );
    }

    return WebViewController();
  }

  @override
  Future<void> wipeAll() async {
    // Process-wide on both engines: CookieManager on Android,
    // WKHTTPCookieStore of the default store on iOS.
    await WebViewCookieManager().clearCookies();
    // clearLocalStorage/clearCache are instance methods, but the instances
    // are process-global too (Android `WebStorage.deleteAllData()`, iOS the
    // default WKWebsiteDataStore) -- a throwaway controller reaches all of
    // it. It is never attached to a widget, so it is collected with the
    // frame.
    final WebViewController scratch = WebViewController();
    await scratch.clearLocalStorage();
    await scratch.clearCache();
  }

  /// Device-wide, by design: it records which SESSION last booted on this
  /// install, the one fact that is about the device and not about a user.
  static const String _lastBootedSessionKey = 'webstorage_last_session';

  /// Boot guard. On the one engine that cannot partition (Android
  /// WebView < 121) the jar is process-wide, so it is wiped at every account
  /// boundary: when the session booting now is not the session that booted
  /// last. Everywhere else this only records the session. Runs BEFORE any
  /// webview can mount (boot stage 1) -- a session "switch" is a cold start.
  static Future<void> ensureAccountBoundary(String sessionAddress) async {
    const storage = ClientWebStorage();
    final prefs = await SharedPreferences.getInstance();
    final current = WebStorageProfileId.account(sessionAddress);
    final last = prefs.getString(_lastBootedSessionKey);
    if (last != current && !await storage.isolates) {
      await storage.wipeAll();
    }
    await prefs.setString(_lastBootedSessionKey, current);
  }
}
