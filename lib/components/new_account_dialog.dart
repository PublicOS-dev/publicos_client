import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/components/action_level_badge.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';
import 'package:publicos_client/widgets/error/revert_reason_l10n.dart';

/// Confirm-sheet for the `/new_account/:payload` route, opened by the
/// sponsor (an existing citizen) after scanning a `publicos-claim:` QR
/// from a new device. Decodes the EIP-712 consent the new device
/// pre-signed, renders the bound values (displayName + new session
/// address + deadline countdown), and on confirm submits
/// `createAccount(...)` with the pre-built sig.
///
/// The new device chose the username on its own device + signed binding
/// to that name + their own key — the sponsor cannot edit either.
/// Sponsor's only choices: confirm or cancel. (Cancel does not retract
/// the sig — only the deadline does that.)
class NewAccountDialog extends StatefulWidget {
  /// The full `publicos-claim:<base64-cbor>` URI scanned from the new
  /// device's QR.
  final String payload;

  const NewAccountDialog({super.key, required this.payload});

  @override
  State<NewAccountDialog> createState() => _NewAccountDialogState();
}

class _NewAccountDialogState extends State<NewAccountDialog> {
  ConsentPayload? _decoded;
  // Decode runs in initState where `context.l10n` is unavailable, so we hold a
  // typed kind (+ the raw exception) and resolve the copy at build time.
  _DecodeErrorKind? _decodeError;
  Object? _decodeException;
  bool _isLoading = false;
  String? _error;
  bool _success = false;

  // Cooldown preview — the sponsor sees whether the chosen name is in
  // cooldown before paying gas. Resolved to copy at build time (set from an
  // async handler that can't safely touch `context`).
  _CooldownInfo? _cooldown;

  // Bootstrap invitation mode. When self-serve creation is paused network-wide,
  // the sponsor spends one of their wave invites instead of a plain create.
  // Loaded once the payload decodes; defaults keep the normal path on failure.
  bool _paused = false;
  int _invitesLeft = 0;
  // DEV: the root account creates invite-free on-chain via
  // Governable._isRoot, so the UI's invite-count gate shouldn't block it.
  bool _creatorIsRoot = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  void _decode() {
    try {
      final p = decodeConsentUri(widget.payload);
      if (p.kind != ConsentKind.newAccount) {
        setState(() => _decodeError = _DecodeErrorKind.wrongKind);
        return;
      }
      setState(() => _decoded = p);
      _checkCooldown(p.displayName!);
      _loadInviteMode();
    } catch (e) {
      setState(() {
        _decodeError = _DecodeErrorKind.malformed;
        _decodeException = e;
      });
    }
  }

  /// Decide whether this sponsorship runs through the normal create path or the
  /// bootstrap invite path, and how many invites the sponsor has. Non-fatal:
  /// any failure leaves [_paused] false so the normal path is used.
  Future<void> _loadInviteMode() async {
    try {
      final paused = await PublicOSAccounts.isAccountCreationPaused();
      final invites = paused ? await PublicOSAccounts.myInvites() : 0;
      final name = paused ? await PublicOSAccounts.myDisplayName() : '';
      if (!mounted) return;
      setState(() {
        _paused = paused;
        _invitesLeft = invites;
        _creatorIsRoot = name.trim().toLowerCase() == 'jmsl';
      });
    } catch (_) {/* keep the normal create path */}
  }

  Future<void> _checkCooldown(String name) async {
    try {
      final until = await PublicOSAccounts.getNameCooldownUntil(name);
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (!mounted) return;
      if (until.toInt() > nowSec) {
        final secs = until.toInt() - nowSec;
        final days = (secs / 86400).ceil();
        setState(() =>
            _cooldown = _CooldownInfo(reserved: days > 365, days: days));
      }
    } catch (_) {/* non-fatal preview check */}
  }

  Future<void> _confirm() async {
    final p = _decoded;
    if (p == null) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final l10n = context.l10n;
    try {
      // While creation is paused, the only open path is the invite flow; spend
      // one of the sponsor's wave invites. Otherwise the normal create.
      final ok = _paused
          ? await PublicOSAccounts.createAccountWithInvite(
              displayName: p.displayName!,
              firstSession: p.newSession,
              deadline: p.deadline,
              sig: p.expandedSig(),
            )
          : await PublicOSAccounts.createAccount(
              displayName: p.displayName!,
              firstSession: p.newSession,
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
            fallback: l10n.revertAccountCreationFailed,
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
            fallback: l10n.revertAccountCreationFailed,
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);

    return Scaffold(
      backgroundColor: tokens.background,
      resizeToAvoidBottomInset: true,
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                  child: Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                    color: tokens.surfaceDeep,
                    borderRadius: BorderRadius.circular(16),
                  ),
                    child: _success
                        ? _buildSuccess(tokens)
                        : _decodeError != null
                            ? _buildDecodeError(tokens)
                            : _decoded == null
                                ? const Center(
                                    child: PhigitalLoadingWidget(size: 24),
                                  )
                                : _buildContent(tokens, _decoded!),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSuccess(GlassTokens tokens) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SuccessIcon(tokens: tokens),
        const SizedBox(height: 20),
        Text(
          l10n.newAccountDialogAccountCreated,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
            color: tokens.starkWhite,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          l10n.newAccountDialogSuccessBody,
          style: TextStyle(color: tokens.textDim, fontSize: 13, height: 1.5),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildDecodeError(GlassTokens tokens) {
    final l10n = context.l10n;
    final errorColor = Theme.of(context).colorScheme.error;
    final message = _decodeError == _DecodeErrorKind.wrongKind
        ? l10n.newAccountDialogErrWrongKind
        : localizedError(l10n, _decodeException,
            fallback: l10n.newAccountDialogErrMalformed);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline_rounded, size: 36, color: errorColor),
        const SizedBox(height: 16),
        Text(
          l10n.newAccountDialogInvalidClaim,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
            color: tokens.starkWhite,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: tokens.textDim, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/'),
          child: Text(l10n.newAccountDialogClose),
        ),
      ],
    );
  }

  Widget _buildContent(GlassTokens tokens, ConsentPayload p) {
    final l10n = context.l10n;
    final errorColor = Theme.of(context).colorScheme.error;
    final addressShort = _short(p.newSession.eip55With0x);
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final remainingSec = p.deadline.toInt() - nowSec;
    final expired = remainingSec <= 0;
    final noInvites = _paused && _invitesLeft <= 0 && !_creatorIsRoot;
    final canSubmit =
        !_isLoading && !expired && _cooldown == null && !noInvites;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Action-level cue: this dialog signs an EIP-712 consent.
              const ActionLevelBadge(ActionLevel.signature),
              const SizedBox(width: 10),
              Text(
                l10n.newAccountDialogCreateTitle,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                  color: tokens.starkWhite,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _paused
              ? l10n.newAccountDialogSponsorPromptPaused
              : l10n.newAccountDialogSponsorPrompt,
          textAlign: TextAlign.center,
          style: TextStyle(color: tokens.textDim, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 20),
        _ClaimRow(
            tokens: tokens,
            label: l10n.newAccountDialogLabelUsername,
            value: p.displayName!),
        const SizedBox(height: 10),
        _ClaimRow(
            tokens: tokens,
            label: l10n.newAccountDialogLabelSession,
            value: addressShort,
            mono: true),
        const SizedBox(height: 10),
        _DeadlineRow(tokens: tokens, remainingSec: remainingSec),
        if (_paused) ...[
          const SizedBox(height: 12),
          _Pill(
            tokens: tokens,
            color: (!_creatorIsRoot && _invitesLeft <= 0)
                ? errorColor
                : tokens.connectedAccent,
            icon: _creatorIsRoot
                ? Icons.shield_rounded
                : (_invitesLeft <= 0
                    ? Icons.block_rounded
                    : Icons.confirmation_number_rounded),
            text: _creatorIsRoot
                ? l10n.newAccountDialogRootInviteFree
                : (_invitesLeft <= 0
                    ? l10n.newAccountDialogNoInvitesLeft
                    : l10n.newAccountDialogInvitesLeft(_invitesLeft)),
          ),
        ],
        if (_cooldown != null) ...[
          const SizedBox(height: 12),
          _Pill(
            tokens: tokens,
            color: tokens.fallbackAccent,
            icon: Icons.lock_clock_rounded,
            text: _cooldown!.reserved
                ? l10n.newAccountDialogReservedName
                : l10n.newAccountDialogNameCooldown(_cooldown!.days),
          ),
        ],
        if (expired) ...[
          const SizedBox(height: 12),
          _Pill(
            tokens: tokens,
            color: errorColor,
            icon: Icons.timer_off_rounded,
            text: l10n.newAccountDialogClaimExpired,
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: errorColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
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
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: tokens.starkWhite,
                  side: BorderSide(color: tokens.borderMedium),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: _isLoading
                    ? null
                    : () => context.canPop() ? context.pop() : context.go('/'),
                child: Text(
                  l10n.actionCancel,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, letterSpacing: 2),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: tokens.starkWhite,
                  foregroundColor: tokens.background,
                  disabledBackgroundColor:
                      tokens.starkWhite.withValues(alpha: 0.4),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: canSubmit ? _confirm : null,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Always laid out (invisible while loading) so the button
                    // keeps the CONFIRM label's height — the loader's larger
                    // footprint does not grow it past the Cancel button.
                    Opacity(
                      opacity: _isLoading ? 0 : 1,
                      child: Text(
                        _paused
                            ? l10n.newAccountDialogUseInvite
                            : l10n.newAccountDialogConfirm,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                    if (_isLoading)
                      Positioned.fill(
                        child: Center(
                          child: OverflowBox(
                            maxWidth: double.infinity,
                            maxHeight: double.infinity,
                            child: PhigitalLoadingWidget(
                              size: 16,
                              showShadows: false,
                              color: tokens.background,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static String _short(String addr) =>
      addr.length > 12 ? '${addr.substring(0, 6)}…${addr.substring(addr.length - 4)}' : addr;
}

/// Why the claim payload could not be turned into a create-account flow.
/// Carried as a typed kind (not pre-built copy) because decode runs in
/// `initState`, before localizations can be looked up.
enum _DecodeErrorKind {
  /// Decoded fine, but it is a different consent kind (e.g. add-session).
  wrongKind,

  /// Could not decode at all; [_NewAccountDialogState._decodeException] holds
  /// the raw error for [localizedError].
  malformed,
}

/// Cooldown preview for the chosen name, resolved to copy at build time.
class _CooldownInfo {
  /// true = name is effectively reserved (cooldown > 1 year); false = a
  /// temporary cooldown measured in [days].
  final bool reserved;
  final int days;
  const _CooldownInfo({required this.reserved, required this.days});
}

// =========================================================================
// Shared row primitives (kept private — these flavours are tuned to the
// dialog and shouldn't leak as general-purpose widgets).
// =========================================================================

class _ClaimRow extends StatelessWidget {
  final GlassTokens tokens;
  final String label;
  final String value;
  final bool mono;
  const _ClaimRow({
    required this.tokens,
    required this.label,
    required this.value,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tokens.glassFillHover,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
                color: tokens.textDim,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: mono ? 11 : 13,
                fontFamily: mono ? 'monospace' : null,
                color: tokens.starkWhite,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(context.l10n.newAccountDialogCopied),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
            child: Icon(Icons.copy, size: 14, color: tokens.textDim),
          ),
        ],
      ),
    );
  }
}

class _DeadlineRow extends StatefulWidget {
  final GlassTokens tokens;
  final int remainingSec;
  const _DeadlineRow({required this.tokens, required this.remainingSec});

  @override
  State<_DeadlineRow> createState() => _DeadlineRowState();
}

class _DeadlineRowState extends State<_DeadlineRow> {
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
        if (snapshot.hasData) _remaining = snapshot.data!;
        final mins = (_remaining ~/ 60).clamp(0, 9999);
        final secs = (_remaining % 60).clamp(0, 59);
        final stale = _remaining <= 60;
        final color = _remaining <= 0
            ? Theme.of(context).colorScheme.error
            : stale
                ? widget.tokens.fallbackAccent
                : widget.tokens.connectedAccent;
        return _ClaimRow(
          tokens: widget.tokens,
          label: context.l10n.newAccountDialogLabelExpiresIn,
          value: _remaining <= 0
              ? context.l10n.newAccountDialogExpired
              : '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}',
          mono: true,
        )._wrappedWith(color);
      },
    );
  }
}

extension on _ClaimRow {
  // Convenience: tinted-border variant for the deadline row's expiring
  // visual. Wraps the base widget in a colored border to draw attention.
  Widget _wrappedWith(Color color) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
      ),
      child: this,
    );
  }
}

class _Pill extends StatelessWidget {
  final GlassTokens tokens;
  final Color color;
  final IconData icon;
  final String text;
  const _Pill({
    required this.tokens,
    required this.color,
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuccessIcon extends StatelessWidget {
  final GlassTokens tokens;
  const _SuccessIcon({required this.tokens});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: tokens.connectedAccent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(
        Icons.check_circle_rounded,
        color: tokens.connectedAccent,
        size: 32,
      ),
    );
  }
}
