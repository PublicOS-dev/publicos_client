import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/theme/glass_theme.dart';

/// Two dialog helpers for displaying secret material (mnemonics and hex
/// private keys) in the glass aesthetic.
///
/// [showSecretRevealDialog] is the simple display dialog used at
/// key-creation time to show a newly-generated mnemonic. Parameterized
/// on title / warning / secret so the same shell handles any secret.
///
/// [showExportKeyDialog] is the per-row "Export" flow from the keychain:
/// a warning gate dialog first ("never share this..."), then a toggle
/// dialog that shows either the mnemonic or the private key. If the key
/// only has one of them (e.g. imported via private key), the toggle is
/// hidden and only the available format renders.

/// Simple glass dialog: title + optional subtitle + warning text + selectable
/// monospace secret + COPY / DONE buttons. [subtitle] is the small dimmed
/// line under the title — used by the keychain to show the key label.
Future<void> showSecretRevealDialog(
  BuildContext context, {
  required String title,
  required String warning,
  required String secret,
  String? subtitle,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final tokens = GlassTokens.of(ctx);
      return Dialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.m),
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: GlassTheme.glassBox(ctx).copyWith(
            color: tokens.surfaceDeep,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                  color: tokens.starkWhite,
                ),
              ),
              if (subtitle != null && subtitle.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: tokens.textDim,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 16),
              Text(
                warning,
                style: TextStyle(
                  color: tokens.textDim,
                  fontSize: 12,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              _SecretBox(secret: secret, tokens: tokens),
              const SizedBox(height: 24),
              _DialogActions(
                onCopy: () =>
                    Clipboard.setData(ClipboardData(text: secret)),
                onDone: () => Navigator.pop(ctx),
                tokens: tokens,
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Per-row "Export" flow for the keychain sheet. Two-step UX:
///
/// 1. Warning gate dialog — "never share this with anyone", user must
///    explicitly acknowledge.
/// 2. Export dialog — if both mnemonic and privateKey are non-null, shows
///    a segmented toggle to switch between them. If only one is
///    available, the toggle is omitted.
Future<void> showExportKeyDialog(
  BuildContext context, {
  required String? mnemonic,
  required String privateKey,
  String keyLabel = '',
}) async {
  final ack = await _showExportWarningDialog(context);
  if (ack != true) return;
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return _ExportSecretDialog(
        mnemonic: mnemonic,
        privateKey: privateKey,
        keyLabel: keyLabel,
      );
    },
  );
}

/// The keychain's "Add to another inbox" (the QR key handoff): a heavy
/// warning gate, then the key itself as a
/// `publicos://link_key/<base64url of the 32 raw bytes>` QR. The other
/// phone's camera opens it in PublicOS, which asks which inbox to add the
/// key to and keeps nothing (`AppInitializer._takeKeyLinkLink` →
/// `ManageInboxIdsPage(linkKey:)`). The QR IS the key: no encryption, no
/// target; the warnings carry the weight.
Future<void> showKeyQrDialog(
  BuildContext context, {
  required Uint8List privateKey,
  String keyLabel = '',
}) async {
  final ack = await _showExportWarningDialog(
    context,
    title: context.l10n.keyQrWarningTitle,
    body: context.l10n.keyQrWarningBody,
  );
  if (ack != true || !context.mounted) return;
  final link =
      'publicos://link_key/${base64Url.encode(privateKey).replaceAll('=', '')}';
  // No screenshots or recordings while THIS QR is up. Only this one: the
  // other QRs are meant to be captured and shared.
  await _setSecureScreen(true);
  try {
    if (!context.mounted) return;
    await _showKeyQr(context, link, keyLabel);
  } finally {
    await _setSecureScreen(false);
  }
}

const _secureScreen = MethodChannel('com.publicos/secure_screen');

/// Android FLAG_SECURE / iOS secure-layer capture blanking (MainActivity.kt,
/// AppDelegate.swift). A no-op everywhere else.
Future<void> _setSecureScreen(bool on) async {
  if (kIsWeb ||
      (defaultTargetPlatform != TargetPlatform.android &&
          defaultTargetPlatform != TargetPlatform.iOS)) {
    return;
  }
  try {
    await _secureScreen.invokeMethod(on ? 'enable' : 'disable');
  } catch (_) {
    // An older native build without the channel: the warnings still stand.
  }
}

Future<void> _showKeyQr(BuildContext context, String link, String keyLabel) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final tokens = GlassTokens.of(ctx);
      return Dialog(
        constraints: const BoxConstraints(
            minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration:
              GlassTheme.glassBox(ctx).copyWith(color: tokens.surfaceDeep),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                ctx.l10n.keyQrTitle(keyLabel.toUpperCase()),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                  color: tokens.starkWhite,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: tokens.fallbackAccent, size: 16),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      ctx.l10n.keyQrNeverShare,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: tokens.fallbackAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Center(
                child: QrImageView(
                  data: link,
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: Colors.transparent,
                  eyeStyle: QrEyeStyle(
                    eyeShape: QrEyeShape.circle,
                    color: tokens.starkWhite,
                  ),
                  dataModuleStyle: QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.circle,
                    color: tokens.starkWhite,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                ctx.l10n.keyQrInstructions,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: tokens.textDim,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: tokens.starkWhite,
                  foregroundColor: tokens.background,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  ctx.l10n.secretDialogsDone,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Future<bool?> _showExportWarningDialog(
  BuildContext context, {
  String? title,
  String? body,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      final tokens = GlassTokens.of(ctx);
      return Dialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: GlassTheme.glassBox(ctx).copyWith(
            color: tokens.surfaceDeep,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Icon(
                  Icons.warning_amber_rounded,
                  color: tokens.fallbackAccent,
                  size: 40,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                title ?? ctx.l10n.secretDialogsShowSecret,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                  color: tokens.starkWhite,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                body ?? ctx.l10n.secretDialogsExportWarning,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: tokens.textDim,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: tokens.starkWhite,
                        side: BorderSide(color: tokens.borderMedium),
                        padding:
                            const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(
                        ctx.l10n.actionCancel,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: tokens.fallbackAccent,
                        foregroundColor: tokens.background,
                        padding:
                            const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(
                        ctx.l10n.secretDialogsIUnderstand,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _ExportSecretDialog extends StatefulWidget {
  final String? mnemonic;
  final String privateKey;
  final String keyLabel;
  const _ExportSecretDialog({
    required this.mnemonic,
    required this.privateKey,
    required this.keyLabel,
  });

  @override
  State<_ExportSecretDialog> createState() => _ExportSecretDialogState();
}

enum _ExportMode { mnemonic, privateKey }

class _ExportSecretDialogState extends State<_ExportSecretDialog> {
  late _ExportMode _mode;

  @override
  void initState() {
    super.initState();
    _mode = widget.mnemonic != null
        ? _ExportMode.mnemonic
        : _ExportMode.privateKey;
  }

  String get _currentSecret {
    if (_mode == _ExportMode.mnemonic && widget.mnemonic != null) {
      return widget.mnemonic!;
    }
    return widget.privateKey;
  }

  String _titleText(BuildContext context) {
    final l10n = context.l10n;
    if (widget.keyLabel.isEmpty) return l10n.secretDialogsExportSecret;
    return l10n.secretDialogsExportLabel(widget.keyLabel.toUpperCase());
  }

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final hasBoth = widget.mnemonic != null;
    return Dialog(
      constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.m),
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: GlassTheme.glassBox(context).copyWith(
          color: tokens.surfaceDeep,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _titleText(context),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
                color: tokens.starkWhite,
              ),
            ),
            const SizedBox(height: 16),
            if (hasBoth)
              _ExportModeToggle(
                mode: _mode,
                onChanged: (m) => setState(() => _mode = m),
                tokens: tokens,
              )
            else
              Text(
                _mode == _ExportMode.mnemonic
                    ? context.l10n.secretDialogsRecoveryPhrase
                    : context.l10n.secretDialogsPrivateKeyHex,
                style: TextStyle(
                  color: tokens.textDim,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
            const SizedBox(height: 16),
            _SecretBox(secret: _currentSecret, tokens: tokens),
            const SizedBox(height: 20),
            _DialogActions(
              onCopy: () => Clipboard.setData(
                ClipboardData(text: _currentSecret),
              ),
              onDone: () => Navigator.pop(context),
              tokens: tokens,
            ),
          ],
        ),
      ),
    );
  }
}

class _ExportModeToggle extends StatelessWidget {
  final _ExportMode mode;
  final ValueChanged<_ExportMode> onChanged;
  final GlassTokens tokens;
  const _ExportModeToggle({
    required this.mode,
    required this.onChanged,
    required this.tokens,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: tokens.glassFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.borderSubtle),
      ),
      child: Row(
        children: [
          _ToggleChip(
            label: context.l10n.secretDialogsMnemonic,
            active: mode == _ExportMode.mnemonic,
            onTap: () => onChanged(_ExportMode.mnemonic),
            tokens: tokens,
          ),
          _ToggleChip(
            label: context.l10n.secretDialogsPrivateKey,
            active: mode == _ExportMode.privateKey,
            onTap: () => onChanged(_ExportMode.privateKey),
            tokens: tokens,
          ),
        ],
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  final GlassTokens tokens;
  const _ToggleChip({
    required this.label,
    required this.active,
    required this.onTap,
    required this.tokens,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active
                ? tokens.starkWhite.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
              color: active ? tokens.starkWhite : tokens.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

class _SecretBox extends StatelessWidget {
  final String secret;
  final GlassTokens tokens;
  const _SecretBox({required this.secret, required this.tokens});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tokens.glassFill,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SelectableText(
        secret,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.5,
          color: tokens.starkWhite,
        ),
      ),
    );
  }
}

class _DialogActions extends StatelessWidget {
  final VoidCallback onCopy;
  final VoidCallback onDone;
  final GlassTokens tokens;
  const _DialogActions({
    required this.onCopy,
    required this.onDone,
    required this.tokens,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: tokens.starkWhite,
              side: BorderSide(color: tokens.borderMedium),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: () {
              onCopy();
              HapticFeedback.lightImpact();
              _showCopiedToast(context, tokens);
            },
            child: Text(
              context.l10n.secretDialogsCopy,
              style: const TextStyle(
                letterSpacing: 1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: tokens.starkWhite,
              foregroundColor: tokens.background,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: onDone,
            child: Text(
              context.l10n.secretDialogsDone,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

OverlayEntry? _copiedToast;

/// Bottom "Key copied" confirmation for the COPY button. iOS gives no system
/// feedback on a clipboard write, so the app shows its own.
///
/// This is an [OverlayEntry] in the ROOT overlay rather than a `SnackBar`: a
/// snackbar belongs to the page's Scaffold, which sits under the dialog's
/// barrier and under the keychain sheet, so it would be dimmed or hidden.
void _showCopiedToast(BuildContext context, GlassTokens tokens) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  final message = context.l10n.secretDialogsKeyCopied;
  _copiedToast?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _CopiedToast(
      message: message,
      tokens: tokens,
      onGone: () {
        if (_copiedToast == entry) _copiedToast = null;
        if (entry.mounted) entry.remove();
      },
    ),
  );
  _copiedToast = entry;
  overlay.insert(entry);
}

class _CopiedToast extends StatefulWidget {
  final String message;
  final GlassTokens tokens;
  final VoidCallback onGone;
  const _CopiedToast({
    required this.message,
    required this.tokens,
    required this.onGone,
  });

  @override
  State<_CopiedToast> createState() => _CopiedToastState();
}

class _CopiedToastState extends State<_CopiedToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  Timer? _hold;

  @override
  void initState() {
    super.initState();
    _fade.forward();
    _hold = Timer(const Duration(milliseconds: 1800), () async {
      await _fade.reverse();
      if (mounted) widget.onGone();
    });
  }

  @override
  void dispose() {
    _hold?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = widget.tokens;
    final bottom = MediaQuery.paddingOf(context).bottom + 24;
    return Positioned(
      left: 24,
      right: 24,
      bottom: bottom,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _fade,
          child: Center(
            child: Material(
              color: tokens.starkWhite,
              borderRadius: BorderRadius.circular(8),
              elevation: 6,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check, size: 16, color: tokens.background),
                    const SizedBox(width: 8),
                    Text(
                      widget.message,
                      style: TextStyle(
                        color: tokens.background,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
