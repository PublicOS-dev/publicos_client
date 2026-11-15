import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:publicos_core/publicos_core.dart'; // PublicOS, PublicOSKeychain
import 'package:publicos_web3_bridge/publicos_web3_bridge.dart'
    show ConnectGate, WalletKey;

import 'package:publicos_client/components/browser/chain_picker_sheet.dart';
import 'package:publicos_client/components/browser/site_keys_sheet.dart';
import 'package:publicos_client/components/chain_icon.dart';
import 'package:publicos_client/data/chain_registry.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/router.dart'; // AppStateNotifier
import 'package:publicos_client/theme/glass_theme.dart';

/// The web-key indicator — the VISIBLE CONSEQUENCE OF A GRANT.
///
/// ── WHAT IT IS ───────────────────────────────────────────────────────────────
/// A pure function of grant state: it exists on screen ONLY when the displayed
/// page is connected ([connected], driven by the host from the bridge's connect
/// events). No grant → nothing in the bar. Tapping it opens the site's key
/// permissions, which is also how a site gets disconnected.
///
/// ── WHY IT SHOWS NO NAME ─────────────────────────────────────────────────────
/// Permission is
/// a SET, so there is no single name to print: showing the first would
/// claim a site sees one key when it may see three, and showing three would
/// grow the action row without telling the user anything they can act on. The
/// glyph answers the only question the address bar should: *is this site
/// connected?* Which keys, and whether to change them, is one tap away.
///
/// ── STILL AN INDICATOR, NOT A VERDICT ────────────────────────────────────────
/// It states connectedness, never whether a key is linked to an account. That
/// judgement is left out on purpose; the signature consumer adjudicates.
class WebKeyIndicator extends StatefulWidget {
  /// Whether the displayed page holds any grant. The host (browser.dart) drives
  /// this from the webview's connect events. false → the widget renders
  /// nothing.
  final bool connected;
  final Uri? origin;

  /// The address the page sees first (`accounts[0]`), from the gate's
  /// `onActiveAccountChanged`. The chip shows that key's emoji, so the icon
  /// says WHICH key a site is using, not just that one is.
  /// Null → the plain key glyph.
  final String? activeAddress;

  /// The picker changed this site's permission or active key; the host bumps
  /// its grants revision so the running page is re-evaluated.
  final VoidCallback? onGrantsChanged;

  /// The chain THIS TAB is on, `0x`-prefixed — from the page's own
  /// `ChainRegistry` via the host. Drives the corner badge; null hides it.
  final String? chainId;

  /// The user picked another chain from the badge. The host owns what happens
  /// next (switch the tab's registry, reload the page) because the registry
  /// belongs to the webview, not to the address bar.
  final ValueChanged<String>? onChainSelected;

  const WebKeyIndicator({
    super.key,
    required this.connected,
    this.origin,
    this.activeAddress,
    this.onGrantsChanged,
    this.chainId,
    this.onChainSelected,
  });

  @override
  State<WebKeyIndicator> createState() => _WebKeyIndicatorState();
}

class _WebKeyIndicatorState extends State<WebKeyIndicator> {
  bool _busy = false;

  /// Emoji of [WebKeyIndicator.activeAddress], resolved off the keychain when
  /// the address changes (a connect, a re-pick) — never per build.
  String? _activeEmoji;

  @override
  void initState() {
    super.initState();
    _resolveActiveEmoji();
  }

  @override
  void didUpdateWidget(covariant WebKeyIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeAddress != widget.activeAddress) _resolveActiveEmoji();
  }

  Future<void> _resolveActiveEmoji() async {
    final wanted = widget.activeAddress?.toLowerCase();
    if (wanted == null) {
      if (_activeEmoji != null && mounted) setState(() => _activeEmoji = null);
      return;
    }
    try {
      final keys = await _availableKeys();
      final key = keys.where((k) => k.address.toLowerCase() == wanted);
      final emoji = key.isEmpty ? null : (key.first.emoji ?? '🔑');
      if (mounted && emoji != _activeEmoji) setState(() => _activeEmoji = emoji);
    } catch (e) {
      debugPrint('[web3] could not resolve the active key emoji: $e');
    }
  }

  String? get _userAddress =>
      AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;

  String get _sessionScope =>
      (PublicOS.sessionBlockchainAddress ?? '').toLowerCase();

  /// Open the site's key permissions.
  ///
  /// Reads and writes through Core directly rather than through the running
  /// `ConnectGate`: the gate lives inside the webview's state and this widget
  /// sits in the address bar above it. The two agree because they share the one
  /// authority that matters — the grant rows, keyed by
  /// [ConnectGate.originKey] — and the host tells the webview to re-read after
  /// this returns.
  Future<void> _openPicker() async {
    final origin = widget.origin;
    final scope = _sessionScope;
    if (origin == null || scope.isEmpty || _busy) return;

    HapticFeedback.lightImpact();
    setState(() => _busy = true);
    try {
      final originKey = ConnectGate.originKey(origin);
      final granted = await PublicOS.database
          .listGrantsForOrigin(origin: originKey, session: scope);
      final keys = await _availableKeys();
      final preferred = await _preferredAddress();
      final activeBefore = await PublicOS.database
          .siteActiveKey(origin: originKey, session: scope);
      if (!mounted) return;

      final result = await SiteKeysSheet.show(
        context: context,
        origin: originKey,
        keys: keys,
        alreadyGranted: granted.map((e) => e.toLowerCase()).toSet(),
        preferred: preferred,
        activeKey: activeBefore,
        sessionKeyName: AppStateNotifier.currentMyContact?.displayName ??
            context.l10n.connectRequestSheetSessionKey,
        currentChainId: widget.chainId,
      );
      // null is a dismissal and changes nothing. An EMPTY visible set is the
      // disconnect gesture and must still be applied.
      if (result == null) return;
      final decision = result.decision;

      final want = decision.visible.map((e) => e.toLowerCase()).toSet();
      final have = granted.map((e) => e.toLowerCase()).toSet();
      final byAddress = {for (final k in keys) k.address: k};

      for (final eoa in want.difference(have)) {
        await PublicOS.database.grantSite(
          origin: originKey,
          session: scope,
          eoa: eoa,
          keyLabel: byAddress[eoa]?.label,
        );
      }
      for (final eoa in have.difference(want)) {
        await PublicOS.database
            .revokeSite(origin: originKey, session: scope, eoa: eoa);
      }
      // The site's active choice rides on a grant row, so it is written AFTER
      // the grants and only inside the visible set.
      final active = decision.activeKey?.toLowerCase();
      if (active != null && want.contains(active)) {
        await PublicOS.database
            .setSiteActiveKey(origin: originKey, session: scope, eoa: active);
      } else {
        await PublicOS.database
            .clearSiteActiveKey(origin: originKey, session: scope);
      }
      final grantsChanged =
          want.length != have.length || !want.containsAll(have);
      if (grantsChanged || active != activeBefore?.toLowerCase()) {
        widget.onGrantsChanged?.call();
      }
      // The chain LAST, because switching reloads the page: doing it before the
      // grant writes above would race a fresh injection against half-written
      // permissions.
      final chainId = result.chainId;
      if (chainId != null) widget.onChainSelected?.call(chainId);
    } catch (e) {
      debugPrint('[web3] site keys picker failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Session key first (it is not in `fetchKeys`), then the keychain. Same order
  /// the bridge's own binding builds, and it decides `accounts[0]` when no
  /// preference applies.
  Future<List<WalletKey>> _availableKeys() async {
    final session = PublicOS.sessionBlockchainAddress;
    final keys = <WalletKey>[
      if (session != null && session.isNotEmpty)
        WalletKey(label: 'session', address: session),
    ];
    final user = _userAddress;
    if (user == null) return keys;
    for (final k in await PublicOSKeychain.fetchKeys(user)) {
      final address = (k['address'] ?? '') as String;
      if (address.isEmpty || address == 'Unknown') continue;
      keys.add(WalletKey(
        label: k['label'] as String,
        address: address,
        emoji: k['emoji'] as String?,
      ));
    }
    return keys;
  }

  Future<String?> _preferredAddress() async {
    final user = _userAddress;
    if (user == null) return PublicOS.sessionBlockchainAddress?.toLowerCase();
    final addr = await PublicOSKeychain.getWebSelectedAddress(user);
    return (addr == null || addr.isEmpty) ? null : addr.toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.connected) return const SizedBox.shrink();

    final tokens = GlassTokens.of(context);

    final chainId = chainIdFromHex(widget.chainId);

    return SizedBox(
      height: 30,
      width: 30,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Tooltip(
              message: context.l10n.webKeyIndicatorTooltip,
              child: InkResponse(
                radius: 24,
                onTap: _openPicker,
                // White, not `connectedAccent`. The teal
                // reads as a status light — "connected, and good" — when the
                // glyph only ever states THAT the site is connected, never a
                // verdict on it. It also matches the desktop twin, whose glyph
                // is derived from the deck frame and lands white on a dark one.
                child: _activeEmoji != null
                    ? Center(
                        child: Text(_activeEmoji!,
                            style: const TextStyle(fontSize: 15, height: 1)))
                    : Icon(Icons.key_outlined,
                        size: 16, color: tokens.starkWhite),
              ),
            ),
          ),
          // The chain badge — WHICH CHAIN this tab reads on, and the only way
          // to change it. It sits on the key glyph because the two answer one
          // question together: who is signing, and where. Its own tap target,
          // so a chain switch is never a mis-tap away from key permissions.
          if (chainId != null)
            Positioned(
              right: -2,
              bottom: -2,
              // ⚠ INFORMATIONAL — the badge does not open a
              // sheet. Chain selection lives in the Connected-keys sheet (one
              // tap further in, on the surface that already owns this site's
              // settings), so the badge states the chain and the key chip is the
              // single tap target here. `_openChainPicker` and
              // `chain_picker_sheet.dart` are both KEPT, unused, in case the
              // badge needs its own picker later.
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.all(1.5),
                  decoration: BoxDecoration(
                    // A ring in the bar's own colour, so the mark reads as a
                    // badge ON the key rather than a second loose glyph.
                    color: tokens.surfaceDeep,
                    shape: BoxShape.circle,
                  ),
                  child: NftChainIcon(chain: chainId, size: 13),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// ⚠ **PARKED, deliberately not deleted.** The standalone
  /// network sheet is not fired from anywhere — chain selection lives
  /// in the Connected-keys sheet. Kept whole, with no call site, in case the badge ever wants its own picker back
  /// (`chain_picker_sheet.dart` is likewise kept and still compiles).
  // ignore: unused_element
  Future<void> _openChainPicker() async {
    if (_busy) return;
    HapticFeedback.lightImpact();
    final picked = await ChainPickerSheet.show(
      context: context,
      currentChainId: widget.chainId,
    );
    // null = dismissed, or the chain it was already on.
    if (picked != null) widget.onChainSelected?.call(picked);
  }
}
