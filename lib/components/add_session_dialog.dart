import 'package:flutter/material.dart';
import 'package:publicos_client/components/key_lifetime_line.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/components/pixel_rain_loading_widget.dart';
import 'package:publicos_client/components/action_level_badge.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/l10n/app_localizations.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';
import 'package:publicos_client/widgets/error/revert_reason_l10n.dart';

/// Confirm-sheet for the `/add_session/:payload` route. Opened after scanning a
/// `publicos-claim:` QR from a new device, which pre-signed an EIP-712
/// `SessionConsent` (account + new key + deadline). This sheet decodes it and
/// routes:
///  - claim's account == mine   → add the new key to my account (`addSession`).
///  - someone else's account & I'm their recovery contact
///                              → start a recovery reseed vote.
///  - otherwise                 → explain there's nothing to do.
class AddSessionDialog extends StatefulWidget {
  /// Full `publicos-claim:<base64-cbor>` URI scanned from the new
  /// device's QR.
  final String payload;

  const AddSessionDialog({super.key, required this.payload});

  @override
  State<AddSessionDialog> createState() => _AddSessionDialogState();
}

/// Height of the Cancel / Authorize action row. Pinned rather than derived from
/// the children: the confirm button swaps its label for a spinner mid-flight,
/// and a loading widget is not the same height as a line of text. Both buttons
/// carry it so the row can never jump.
const double _kActionButtonHeight = 48;

/// Extent of the in-button spinner. Comfortably inside [_kActionButtonHeight],
/// and close to the cap height of the label it replaces.
const double _kActionSpinnerSize = 20;

/// Why a scanned claim can't be acted on. Held as a kind rather than a
/// localized string because the decode runs from `initState`, where inherited
/// widgets — and so `context.l10n` — are not yet reachable. `build` turns the
/// kind into a sentence.
enum _ClaimFailure {
  expiringRecovery,
  wrongKind,
  malformedPayload,
  foreignAccount,
  notRecoveryContact,
  recoveryCheckFailed,
}

class _AddSessionDialogState extends State<AddSessionDialog> {
  ConsentPayload? _decoded;
  _ClaimFailure? _failure;

  /// The exception behind [_failure], when there was one. Feeds
  /// [localizedError] so a mapped Core message beats the generic fallback.
  Object? _failureCause;

  bool _isLoading = false;
  String? _error;
  bool _success = false;

  // Recovery routing: set when the scanned claim is for ANOTHER account that
  // I'm a recovery contact of. The action then becomes
  // "start a reseed vote" rather than "add to my account".
  bool _recoveryMode = false;
  bool _checkingRecovery = false;
  EthereumAddress? _recoveryTarget;
  String? _recoveryTargetName;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  /// Runs from `initState`, so it must not touch `context`. Assigns fields
  /// directly — the first build has not happened yet, so there is nothing to
  /// notify.
  void _decode() {
    try {
      final p = decodeConsentUri(widget.payload);
      if (p.kind != ConsentKind.addSession) {
        _failure = _ClaimFailure.wrongKind;
        return;
      }
      final myAddr = PublicOS.myPublicosAddress?.toLowerCase();
      if (p.ttl > BigInt.zero &&
          p.account!.eip55With0x.toLowerCase() != myAddr) {
        // Recovery always installs a PERMANENT key (the reseed signs ttl 0),
        // so an expiring claim can never pass as a recovery code.
        _failure = _ClaimFailure.expiringRecovery;
        return;
      }
      final myAddrHex = PublicOS.myPublicosAddress;
      final claimAccount = p.account!;
      final isMine = myAddrHex != null &&
          claimAccount.eip55With0x.toLowerCase() == myAddrHex.toLowerCase();
      if (isMine) {
        _decoded = p;
        return;
      }
      // The claim is for someone else's account. The only legitimate use is
      // recovery: if I'm a recovery contact of that account, this can start a
      // reseed vote installing the new key as its sole session.
      if (myAddrHex == null) {
        _failure = _ClaimFailure.foreignAccount;
        return;
      }
      _checkingRecovery = true;
      _routeAsRecovery(p, claimAccount, myAddrHex);
    } catch (e) {
      _failure = _ClaimFailure.malformedPayload;
      _failureCause = e;
    }
  }

  Future<void> _routeAsRecovery(
      ConsentPayload p, EthereumAddress target, String myAddrHex) async {
    try {
      final info = await PublicOSRecovery.getAccountRecoveryContacts(target);
      final myAddr = myAddrHex.toLowerCase();
      final amContact =
          info.contacts.any((c) => c.eip55With0x.toLowerCase() == myAddr);
      if (!mounted) return;
      if (!amContact) {
        setState(() {
          _checkingRecovery = false;
          _failure = _ClaimFailure.notRecoveryContact;
        });
        return;
      }
      Contact? targetContact;
      try {
        targetContact = await PublicOSContacts.fetchContact(target);
      } catch (_) {/* fall back to the raw address */}
      if (!mounted) return;
      setState(() {
        _checkingRecovery = false;
        _recoveryMode = true;
        _recoveryTarget = target;
        _recoveryTargetName = targetContact?.displayName;
        _decoded = p;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checkingRecovery = false;
        _failure = _ClaimFailure.recoveryCheckFailed;
        _failureCause = e;
      });
    }
  }

  String _failureMessage(AppLocalizations l10n) {
    switch (_failure!) {
      case _ClaimFailure.wrongKind:
        return l10n.addSessionDialogWrongKind;
      case _ClaimFailure.expiringRecovery:
        return l10n.addSessionDialogRecoveryNeedsPermanent;
      case _ClaimFailure.malformedPayload:
        return localizedError(l10n, _failureCause,
            fallback: l10n.addSessionDialogMalformedPayload);
      case _ClaimFailure.foreignAccount:
        return l10n.addSessionDialogForeignAccount;
      case _ClaimFailure.notRecoveryContact:
        return l10n.addSessionDialogNotRecoveryContact;
      case _ClaimFailure.recoveryCheckFailed:
        return localizedError(l10n, _failureCause,
            fallback: l10n.addSessionDialogRecoveryCheckFailed);
    }
  }

  Future<void> _confirm() async {
    final p = _decoded;
    if (p == null) return;
    final l10n = context.l10n;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final ok = await PublicOSAccounts.addSession(
        newSession: p.newSession,
        deadline: p.deadline,
        sig: p.expandedSig(),
        // The lifetime the new key signed. Must match the
        // consent, or the contract rejects it.
        ttl: p.ttl,
      );

      if (!mounted) return;
      if (!ok) {
        setState(() {
          _isLoading = false;
          _error = localizedRevertReason(
            l10n,
            PublicOS.lastError,
            fallback: l10n.revertAuthorizeFailed,
          );
        });
        return;
      }

      setState(() {
        _isLoading = false;
        _success = true;
      });

      await Future.delayed(const Duration(seconds: 2));
      if (mounted) context.go('/');
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = localizedRevertReason(
            l10n,
            PublicOS.lastError ?? e.toString(),
            fallback: l10n.revertAuthorizeFailed,
          );
        });
      }
    }
  }

  /// Recovery-mode action: start a reseed vote for another account I'm a
  /// recovery contact of, using the new key + sig from the scanned claim.
  Future<void> _confirmRecovery() async {
    final p = _decoded;
    final target = _recoveryTarget;
    if (p == null || target == null) return;
    final l10n = context.l10n;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final ok = await PublicOSRecovery.startRecoveryVote(
        targetAccountAddress: target,
        proposedSessionAddress: p.newSession,
        deadline: p.deadline,
        sig: p.expandedSig(),
      );
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _isLoading = false;
          _error = localizedRevertReason(
            l10n,
            PublicOS.lastError,
            fallback: l10n.revertRecoveryFailed,
          );
        });
        return;
      }
      setState(() {
        _isLoading = false;
        _success = true;
      });
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) context.go('/');
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = localizedRevertReason(
            l10n,
            PublicOS.lastError ?? e.toString(),
            fallback: l10n.revertRecoveryFailed,
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    // Styled in the borderless key / sign family: a flat surfaceDeep card, no
    // blur, no hairlines;
    // tone steps carry every edge, like connect_request_sheet.
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.m),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          decoration: BoxDecoration(
            color: tokens.surfaceDeep,
            borderRadius: BorderRadius.circular(20),
          ),
          child: SingleChildScrollView(
            child: _success
                ? _buildSuccess(tokens)
                : _failure != null
                    ? _buildDecodeError(tokens)
                    : (_decoded == null || _checkingRecovery)
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(child: PhigitalLoadingWidget(size: 24)),
                          )
                        : _buildContent(tokens, _decoded!),
          ),
        ),
      ),
    );
  }

  /// Icon tile + plain title (+ the signature badge on the ask itself).
  Widget _header(GlassTokens tokens, IconData icon, Color color, String title,
      {bool signature = false}) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: tokens.glassFill,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 19),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: tokens.starkWhite,
            ),
          ),
        ),
        if (signature) const ActionLevelBadge(ActionLevel.signature),
      ],
    );
  }

  TextStyle _label(GlassTokens t) => TextStyle(
        fontFamily: 'SpaceGrotesk',
        fontWeight: FontWeight.w800,
        fontSize: 10,
        letterSpacing: 1.2,
        color: t.textDim,
      );

  TextStyle _body(GlassTokens t) =>
      TextStyle(color: t.textDim, fontSize: 13, height: 1.5);

  ButtonStyle _secondaryStyle(GlassTokens tokens) => OutlinedButton.styleFrom(
        foregroundColor: tokens.starkWhite,
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide.none,
      );

  static const TextStyle _buttonText = TextStyle(
    fontFamily: 'SpaceGrotesk',
    fontWeight: FontWeight.w800,
    letterSpacing: 1.5,
    fontSize: 12,
  );

  void _close() => context.canPop() ? context.pop() : context.go('/');

  Widget _buildSuccess(GlassTokens tokens) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(
          tokens,
          Icons.check_circle_rounded,
          tokens.connectedAccent,
          _recoveryMode
              ? l10n.addSessionDialogRecoveryVoteStartedTitle
              : l10n.addSessionDialogDeviceAuthorizedTitle,
        ),
        const SizedBox(height: 14),
        Text(
          _recoveryMode
              ? l10n.addSessionDialogRecoverySuccessBody
              : l10n.addSessionDialogAuthorizedSuccessBody,
          style: _body(tokens),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildDecodeError(GlassTokens tokens) {
    final l10n = context.l10n;
    final errorColor = Theme.of(context).colorScheme.error;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(tokens, Icons.error_outline_rounded, errorColor,
            l10n.addSessionDialogInvalidClaimTitle),
        const SizedBox(height: 14),
        Text(_failureMessage(l10n), style: _body(tokens)),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: _kActionButtonHeight,
          child: OutlinedButton(
            style: _secondaryStyle(tokens),
            onPressed: _close,
            child: Text(l10n.addSessionDialogClose, style: _buttonText),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(GlassTokens tokens, ConsentPayload p) {
    final l10n = context.l10n;
    final errorColor = Theme.of(context).colorScheme.error;
    final addrHex = p.newSession.eip55With0x;
    final truncated = addrHex.length > 12
        ? '${addrHex.substring(0, 6)}...${addrHex.substring(addrHex.length - 4)}'
        : addrHex;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final remainingSec = p.deadline.toInt() - nowSec;
    final expired = remainingSec <= 0;
    final isRecovery = _recoveryMode;
    final targetLabel = _recoveryTargetName ?? l10n.addSessionDialogThisAccount;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(
          tokens,
          isRecovery ? Icons.health_and_safety_outlined : Icons.key_rounded,
          isRecovery ? tokens.fallbackAccent : tokens.connectedAccent,
          isRecovery
              ? l10n.addSessionDialogHelpRecoverTitle
              : l10n.addSessionDialogAuthorizeSessionTitle,
          signature: true,
        ),
        const SizedBox(height: 16),
        Text(
          isRecovery
              ? l10n.addSessionDialogRecoveryBody(targetLabel, truncated)
              : l10n.addSessionDialogAuthorizeBody(truncated),
          style: _body(tokens),
        ),
        const SizedBox(height: 18),
        // NEW SESSION — the address being added, tap to copy.
        Text(l10n.addSessionDialogNewSessionLabel, style: _label(tokens)),
        const SizedBox(height: 6),
        Material(
          color: tokens.glassFill,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              Clipboard.setData(ClipboardData(text: addrHex));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(l10n.addSessionDialogAddressCopied),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      addrHex,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: tokens.starkWhite,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.copy_rounded, size: 14, color: tokens.textDim),
                ],
              ),
            ),
          ),
        ),
        if (!isRecovery) ...[
          const SizedBox(height: 18),
          // KEY LIFETIME — what is being approved: a permanent
          // key, or one that ends `ttl` after this tx.
          Text(l10n.keyLifetimeTitle, style: _label(tokens)),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                p.ttl == BigInt.zero ? Icons.all_inclusive_rounded : Icons.timer_outlined,
                size: 16,
                color: tokens.starkWhite,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  p.ttl == BigInt.zero
                      ? l10n.addSessionDialogLifetimePermanent
                      : l10n.addSessionDialogLifetimeExpiring(
                          formatKeyLifetime(l10n, p.ttl.toInt())),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: tokens.starkWhite,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 18),
        _DeadlineChip(tokens: tokens, remainingSec: remainingSec),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, color: tokens.fallbackAccent, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isRecovery
                    ? l10n.addSessionDialogRecoveryWarning(targetLabel)
                    : l10n.addSessionDialogAuthorizeWarning,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                  color: tokens.fallbackAccent,
                ),
              ),
            ),
          ],
        ),
        if (expired) ...[
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.timer_off_rounded, color: errorColor, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.addSessionDialogClaimExpired,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                    color: errorColor,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: errorColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '> $_error',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: errorColor,
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: _kActionButtonHeight,
                child: OutlinedButton(
                  style: _secondaryStyle(tokens),
                  onPressed: _isLoading ? null : _close,
                  child: Text(l10n.actionCancel, style: _buttonText),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: SizedBox(
                height: _kActionButtonHeight,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: tokens.glassFill,
                    foregroundColor: tokens.starkWhite,
                    disabledBackgroundColor: tokens.glassFill.withValues(alpha: 0.4),
                    elevation: 0,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: _isLoading || expired
                      ? null
                      : (isRecovery ? _confirmRecovery : _confirm),
                  child: _isLoading
                      ? const PixelRainLoadingWidget(
                          size: _kActionSpinnerSize,
                          showShadows: false,
                        )
                      : Text(
                          isRecovery
                              ? l10n.addSessionDialogStartVoteButton
                              : l10n.addSessionDialogAuthorizeButton,
                          style: _buttonText,
                        ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _DeadlineChip extends StatefulWidget {
  final GlassTokens tokens;
  final int remainingSec;
  const _DeadlineChip({required this.tokens, required this.remainingSec});

  @override
  State<_DeadlineChip> createState() => _DeadlineChipState();
}

class _DeadlineChipState extends State<_DeadlineChip> {
  late int _remaining;
  late final Stream<int> _ticks;

  @override
  void initState() {
    super.initState();
    _remaining = widget.remainingSec;
    _ticks = Stream<int>.periodic(const Duration(seconds: 1), (i) => i)
        .map((_) => _remaining - 1)
        .asBroadcastStream();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: _ticks,
      builder: (context, snapshot) {
        final l10n = context.l10n;
        if (snapshot.hasData) _remaining = snapshot.data!;
        final mins = (_remaining ~/ 60).clamp(0, 9999);
        final secs = (_remaining % 60).clamp(0, 59);
        final stale = _remaining <= 60;
        final color = _remaining <= 0
            ? Theme.of(context).colorScheme.error
            : stale
                ? widget.tokens.fallbackAccent
                : widget.tokens.connectedAccent;
        final text = _remaining <= 0
            ? l10n.addSessionDialogDeadlineExpired
            : l10n.addSessionDialogDeadlineExpiresIn(
                '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}');
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.schedule_rounded, color: color, size: 14),
              const SizedBox(width: 6),
              Text(
                text,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
