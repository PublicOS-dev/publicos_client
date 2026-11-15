import 'package:publicos_core/publicos_core.dart';
import 'package:publicos_client/components/contact_banner.dart';
import 'package:flutter/material.dart';
import 'package:publicos_web3_bridge/publicos_web3_bridge.dart'
    show WebStorageProfileId;
import 'package:web3dart/web3dart.dart' show EthPrivateKey;
import 'package:zero_cached_image/zero_cached_image.dart';
import 'package:publicos_client/components/browser/publicos_webview.dart';
import 'package:publicos_client/router.dart';
import 'package:publicos_client/theme/glass_theme.dart';

class WalletManagerSheet extends StatefulWidget {
  final AppBookmark app;
  final Contact? ownerContact;
  final Map<String, dynamic> wallet;

  /// Status-bar height, measured at the CALL SITE. MediaQuery's padding/
  /// viewPadding both read 0 inside `showModalBottomSheet`, so the sheet can't
  /// measure the notch itself — the host passes it in so the sheet can end
  /// right at the notification bar.
  final double topInset;

  const WalletManagerSheet({
    super.key,
    required this.app,
    this.ownerContact,
    required this.wallet,
    this.topInset = 0,
  });

  @override
  State<WalletManagerSheet> createState() => _WalletManagerSheetState();
}

class _WalletManagerSheetState extends State<WalletManagerSheet>
    with SingleTickerProviderStateMixin {
  // Live downward translation while dragging the handle (0 = resting at full
  // size). The sheet follows the finger; on release it either flings off to
  // dismiss or springs back to 0. The webview owns every other vertical
  // gesture, so its scroll isn't hijacked.
  double _dragOffset = 0;
  late final AnimationController _springController;
  Animation<double>? _springAnim;

  // The key that signs for the wallet being managed. The dApp connects to
  // widget.wallet['address'] (the Safe address for a Safe, the EOA for a
  // keychain key); this is the matching signer.
  EthPrivateKey? _signingKey;

  @override
  void initState() {
    super.initState();
    _springController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(() {
        if (_springAnim != null) {
          setState(() => _dragOffset = _springAnim!.value);
        }
      });
    _resolveManagedSigningKey();
  }

  @override
  void dispose() {
    _springController.dispose();
    super.dispose();
  }

  /// Resolve the signer for the managed wallet: a keychain EOA signs with its
  /// own key; a Safe (main/group) or a link we don't hold the key for signs
  /// with the account owner key for now (EIP-1271 / Safe-routing deferred).
  Future<void> _resolveManagedSigningKey() async {
    EthPrivateKey? key;
    try {
      final account =
          AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
      final isKeychain = widget.wallet['isKeychain'] == true;
      final label = widget.wallet['name'] as String?;
      if (isKeychain && account != null && label != null) {
        final hex = await PublicOSKeychain.exportPrivateKey(account, label);
        if (hex != null) key = EthPrivateKey.fromHex(hex);
      }
    } catch (_) {
      // Fall through to the owner key.
    }
    key ??= PublicOS.currentBlockchainPrivateKey;
    if (mounted) setState(() => _signingKey = key);
  }

  String _formatAddress(String address) {
    if (address.length < 10) return address;
    return '${address.substring(0, 6)}...${address.substring(address.length - 4)}';
  }

  void _onHandleDragStart(DragStartDetails _) {
    // Grab during a spring-back → take over from wherever it is.
    if (_springController.isAnimating) _springController.stop();
  }

  void _onHandleDragUpdate(DragUpdateDetails d) {
    setState(() {
      // Only downward; can't drag above the resting position.
      _dragOffset =
          (_dragOffset + (d.primaryDelta ?? 0)).clamp(0.0, double.infinity);
    });
  }

  void _onHandleDragEnd(DragEndDetails details, double sheetHeight) {
    final velocity = details.primaryVelocity ?? 0;
    // Completed gesture = dragged past ~30% of the sheet, or a downward fling.
    final dismiss = _dragOffset > sheetHeight * 0.3 || velocity > 700;
    if (dismiss) {
      // Let the modal's own reverse transition slide it the rest of the way;
      // _dragOffset stays where the finger left it so there's no jump.
      Navigator.of(context).pop();
    } else {
      _springBackTo(0);
    }
  }

  void _springBackTo(double target) {
    _springAnim = Tween<double>(begin: _dragOffset, end: target).animate(
        CurvedAnimation(parent: _springController, curve: Curves.easeOutCubic));
    _springController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final media = MediaQuery.of(context);
    // Both padding.top AND viewPadding.top read 0 inside showModalBottomSheet,
    // so the inset is measured by the host and passed in (widget.topInset).
    final topInset = widget.topInset;

    final iconUrl = widget.app.icon;
    final fallbackColor =
        widget.ownerContact?.iconColor ?? tokens.connectedAccent;

    // The sheet ENDS at the status/notification bar: height = screen minus the
    // status-bar inset, bottom-anchored, so its top (and the handle) sit just
    // BELOW the notification bar — out of the OS notification-shade pull-down
    // zone, so the handle is draggable. The status-bar strip stays the modal
    // scrim, showing the explorer behind. Top bar = the owner's darkened banner.
    // Transform.translate makes the whole sheet follow the handle drag, exposing
    // the scrim/explorer above as it slides down.
    final sheetHeight = media.size.height - topInset;
    return SizedBox(
      height: sheetHeight,
      child: Transform.translate(
        offset: Offset(0, _dragOffset),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: tokens.surfaceDeep,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: [
              BoxShadow(
                color: tokens.glassShadow,
                offset: const Offset(0, -4),
                blurRadius: 24,
              ),
            ],
          ),
          child: Column(
            children: [
              _buildBannerTopBar(
                  tokens, sheetHeight, fallbackColor, iconUrl),
              const SizedBox(height: 2),
              Expanded(
                child: SafeArea(
                  top: false,
                  child: PublicOSWebView(
                    initialUrl: widget.app.url ?? '',
                    // Its own jar: the wallet dApp never shares cookies with
                    // an app tab of this account. A mounted wallet sheet with
                    // no session address is a broken invariant -- loud, not a
                    // fallback into the account's jar.
                    profileId: WebStorageProfileId.wallet(
                      PublicOS.sessionBlockchainAddress!,
                    ),
                    // Pin the dApp to the wallet pressed "Manage" (Safe address
                    // for a Safe, EOA for a keychain key), not the global key.
                    overrideAccountAddress: widget.wallet['address'] as String?,
                    overrideSigningKey: _signingKey,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBannerTopBar(
    GlassTokens tokens,
    double sheetHeight,
    Color fallbackColor,
    String? iconUrl,
  ) {
    final walletName = widget.wallet['name'] as String? ?? 'main';
    final walletAddress = widget.wallet['address'] as String? ?? '';
    final walletEmoji = widget.wallet['emoji'] as String?;
    final ownerName = widget.ownerContact?.displayName ?? 'Unknown';
    final appName = widget.app.displayName;

    Widget bannerFallback() => ColoredBox(color: fallbackColor);

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Stack(
        children: [
          // Banner background (full bleed, behind the status bar like the browser).
          Positioned.fill(
            child: ContactBanner(
              contact: widget.ownerContact,
              fallback: bannerFallback(),
            ),
          ),
          // Darkening vignette — keeps the handle + text legible on any banner.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.6),
                    Colors.black.withValues(alpha: 0.35),
                    Colors.black.withValues(alpha: 0.7),
                  ],
                  stops: const [0.0, 0.4, 1.0],
                ),
              ),
            ),
          ),
          // Foreground: handle → header row. The sheet already starts below the
          // status bar (see build), so no notch spacer is needed here.
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 6),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: _onHandleDragStart,
                onVerticalDragUpdate: _onHandleDragUpdate,
                onVerticalDragEnd: (d) => _onHandleDragEnd(d, sheetHeight),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: Row(
                  children: [
                    // App icon
                    Container(
                      width: 30,
                      height: 30,
                      // Unframed — the app art stands on its own.
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: iconUrl != null && iconUrl.isNotEmpty
                            ? ZeroCachedImage(
                                imageUrl: iconUrl,
                                fit: BoxFit.cover,
                                placeholder: (_, __) =>
                                    ColoredBox(color: fallbackColor),
                                errorWidget: (_, __, ___) => Icon(
                                    Icons.apps_rounded,
                                    size: 16,
                                    color: Colors.white.withValues(alpha: 0.8)),
                              )
                            : Icon(Icons.apps_rounded,
                                size: 16,
                                color: Colors.white.withValues(alpha: 0.8)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '$ownerName.$appName',
                        style: const TextStyle(
                          fontFamily: 'SpaceGrotesk',
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Wallet emoji + name + address
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (walletEmoji != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Text(walletEmoji,
                                style: const TextStyle(fontSize: 16)),
                          ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              walletName,
                              style: const TextStyle(
                                fontFamily: 'SpaceGrotesk',
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              _formatAddress(walletAddress),
                              style: TextStyle(
                                fontSize: 10,
                                fontFamily: 'monospace',
                                color: Colors.white.withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
