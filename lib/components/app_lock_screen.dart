import 'dart:io' show Platform, exit;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/utils/open_app_system_settings.dart';

/// The app's own lock, shown at boot in place of the phone's lock prompt
/// when the phone has no screen lock, or when an app PIN already exists.
///
/// The rules are Core's (`PublicOSAuth`, app PIN section): six digits, ten
/// wrong tries lock it for good, and a forgotten or locked PIN has one way
/// out, a reset of everything the app keeps on this phone.
///
/// [onDone] re-runs the boot. It is called once the PIN unlocked the app
/// (Core has set `isAuthenticated`), or when the person says they set a
/// screen lock (the boot then asks the phone for it).
class AppLockScreen extends StatefulWidget {
  final AuthGate gate;
  final VoidCallback onDone;

  const AppLockScreen({super.key, required this.gate, required this.onDone});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

enum _Mode { noLock, setPin, confirmPin, enterPin, locked, resetDone }

class _AppLockScreenState extends State<AppLockScreen> {
  late _Mode _mode;
  final _pin = TextEditingController();
  final _focus = FocusNode();
  String? _firstPin;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _mode = switch (widget.gate) {
      AuthGate.appPin => _Mode.enterPin,
      AuthGate.appPinLocked => _Mode.locked,
      _ => _Mode.noLock,
    };
  }

  @override
  void dispose() {
    _pin.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _show(_Mode mode, {String? error}) {
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _error = error;
      _busy = false;
      _pin.clear();
    });
    if (mode == _Mode.setPin ||
        mode == _Mode.confirmPin ||
        mode == _Mode.enterPin) {
      _focus.requestFocus();
    }
  }

  Future<void> _onPinTyped(String value) async {
    if (_busy || value.length != PublicOSAuth.pinLength) return;
    final l10n = context.l10n;
    switch (_mode) {
      case _Mode.setPin:
        _firstPin = value;
        _show(_Mode.confirmPin);
      case _Mode.confirmPin:
        if (value != _firstPin) {
          _firstPin = null;
          _show(_Mode.setPin, error: l10n.lockPinMismatch);
          return;
        }
        setState(() => _busy = true);
        var ok = false;
        try {
          ok = await PublicOSAuth.setPin(value);
        } catch (_) {}
        _firstPin = null;
        if (ok) {
          widget.onDone();
        } else {
          _show(_Mode.setPin, error: l10n.errorGeneric);
        }
      case _Mode.enterPin:
        setState(() => _busy = true);
        final result = await PublicOSAuth.verifyPin(value);
        switch (result) {
          case PinCheck.ok:
            widget.onDone();
          case PinCheck.locked:
            _show(_Mode.locked);
          case PinCheck.wrong:
            final left = await PublicOSAuth.pinAttemptsLeft();
            _show(_Mode.enterPin, error: l10n.lockWrongPin(left));
        }
      default:
        break;
    }
  }

  Future<void> _confirmReset() async {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: tokens.surfaceDeep,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: tokens.borderSubtle),
        ),
        title: Text(
          l10n.lockResetTitle,
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            color: tokens.starkWhite,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          l10n.lockResetBody,
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            color: tokens.textDim,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              l10n.dlgCancel,
              style: TextStyle(
                  fontFamily: 'SpaceGrotesk', color: tokens.textDim),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              l10n.lockResetConfirm,
              style: TextStyle(
                fontFamily: 'SpaceGrotesk',
                color: tokens.fallbackAccent,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);

    // Android: the system deletes all of the app's data and ends the
    // process; on success the next line is never reached.
    if (await clearAppDataNatively()) return;

    await PublicOSAuth.wipeLocalData();
    // Core is closed and its files are gone: this process cannot go on.
    // Android can leave by itself; iOS shows the "open it again" screen.
    if (!kIsWeb && Platform.isAndroid) {
      await SystemNavigator.pop();
      exit(0);
    }
    _show(_Mode.resetDone);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    final isPinMode = _mode == _Mode.setPin ||
        _mode == _Mode.confirmPin ||
        _mode == _Mode.enterPin;

    final (String title, String? body) = switch (_mode) {
      _Mode.noLock => (l10n.lockNoLockTitle, l10n.lockNoLockBody),
      _Mode.setPin => (l10n.lockSetPinTitle, l10n.lockSetPinBody),
      _Mode.confirmPin => (l10n.lockConfirmPinTitle, null),
      _Mode.enterPin => (l10n.lockEnterPinTitle, null),
      _Mode.locked => (l10n.lockLockedTitle, l10n.lockLockedBody),
      _Mode.resetDone => (l10n.lockResetDoneTitle, l10n.lockResetDoneBody),
    };

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [const Color(0xFF0F0F0F), tokens.background],
                  center: Alignment.center,
                  radius: 1.5,
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _mode == _Mode.locked
                          ? Icons.lock_rounded
                          : Icons.lock_outline_rounded,
                      color: _mode == _Mode.locked
                          ? Theme.of(context).colorScheme.error
                          : tokens.starkWhite,
                      size: 40,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        color: tokens.starkWhite,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (body != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        body,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'SpaceGrotesk',
                          color: tokens.textDim,
                          fontSize: 14,
                          height: 1.45,
                        ),
                      ),
                    ],
                    if (isPinMode) ...[
                      const SizedBox(height: 28),
                      Container(
                        constraints: const BoxConstraints(maxWidth: 260),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: GlassTheme.glassBox(context),
                        child: TextField(
                          controller: _pin,
                          focusNode: _focus,
                          autofocus: true,
                          enabled: !_busy,
                          obscureText: true,
                          enableSuggestions: false,
                          autocorrect: false,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          maxLength: PublicOSAuth.pinLength,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          style: TextStyle(
                            color: tokens.starkWhite,
                            fontSize: 28,
                            letterSpacing: 12,
                          ),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            counterText: '',
                          ),
                          onChanged: _onPinTyped,
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'SpaceGrotesk',
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 13,
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                    ..._actions(context),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _actions(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    final error = Theme.of(context).colorScheme.error;
    final isAndroid = !kIsWeb && Platform.isAndroid;

    Widget button(String label, VoidCallback onTap, {Color? color}) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextButton(
            onPressed: _busy ? null : onTap,
            style: TextButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              backgroundColor: Colors.white.withValues(alpha: 0.05),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30)),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'SpaceGrotesk',
                color: color ?? tokens.starkWhite,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        );

    switch (_mode) {
      case _Mode.noLock:
        return [
          if (isAndroid)
            button(l10n.lockOpenSettings, openDeviceSecuritySettings),
          button(l10n.lockIHaveSetLock, widget.onDone),
          button(l10n.lockSetPinInstead, () => _show(_Mode.setPin),
              color: tokens.textDim),
        ];
      case _Mode.setPin:
      case _Mode.confirmPin:
        return [
          button(l10n.dlgCancel, () {
            _firstPin = null;
            _show(_Mode.noLock);
          }, color: tokens.textDim),
        ];
      case _Mode.enterPin:
        return [
          button(l10n.lockForgotPin, _confirmReset, color: tokens.textDim),
        ];
      case _Mode.locked:
        return [button(l10n.lockResetButton, _confirmReset, color: error)];
      case _Mode.resetDone:
        return const [];
    }
  }
}
