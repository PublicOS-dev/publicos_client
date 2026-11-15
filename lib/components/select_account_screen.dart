import 'dart:async';
import 'package:publicos_client/components/contact_banner.dart';
import 'dart:convert';
import 'dart:ui';
import 'package:publicos_core/publicos_core.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:publicos_client/components/key_lifetime_line.dart';
import 'package:flutter/services.dart';
import 'package:publicos_client/app_initializer.dart';
import 'package:publicos_client/components/app_version_label.dart';
import 'package:publicos_client/components/glass_contact_icon.dart';
import 'package:publicos_client/components/import_key_sheet.dart';
import 'package:publicos_client/components/link_device_dialog.dart';
import 'package:publicos_client/components/new_account_ask_dialog.dart';
import 'package:publicos_client/components/new_key_flow_dialog.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/l10n/app_localizations.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';
import 'package:publicos_client/l10n/boot_phase.dart';
import 'package:publicos_client/components/pixel_rain_loading_widget.dart';
import 'package:publicos_client/components/secret_dialogs.dart';
import 'package:publicos_client/pages/profile_qr_page.dart';
import 'package:publicos_client/providers/theme_provider.dart';
import 'package:publicos_client/router.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wallet/wallet.dart';

/// Select Account Screen - "ID Badge" Design
///
/// Each identity presented as a physical ID card with depth and presence.
/// Inspired by modern municipal ID cards - clean, authoritative, trustworthy.
class SelectAccountScreen extends StatefulWidget {
  const SelectAccountScreen({super.key});

  @override
  State<SelectAccountScreen> createState() => _SelectAccountScreenState();
}

class _SelectAccountScreenState extends State<SelectAccountScreen> {
  Map<String, EthereumAddress> _accounts = {};
  Map<String, Contact> _accountContacts = {};
  bool _isLoadingData = true;
  bool _isProcessingAction = false;
  String? _loadingAccountName;
  String? _lastUsedAccountAddress;

  bool _hasTemporaryKeys = false;
  String? _temporaryKeysAddress;
  // Unix-seconds deadline of the persisted signed link-device claim, if the
  // temp key has one. Drives the live countdown chip on the pending card.
  int? _temporaryClaimDeadline;

  String _bootStatus = '';

  // Checks a pending key's activation every 20 s, so the
  // user doesn't have to press CHECK ACTIVATION. Silent when not linked yet.
  Timer? _activationPoller;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _loadData();
    _activationPoller =
        Timer.periodic(const Duration(seconds: 20), (_) => _pollActivation());
    // The claim page's import QR (publicos://import_key/…) lands in the app
    // state; this screen is where it is confirmed. Checked once the first
    // frame is up (a cold-start link) and on every change (a link while open).
    AppStateNotifier.instance?.addListener(_onAppStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onAppStateChanged());
  }

  @override
  void dispose() {
    AppStateNotifier.instance?.removeListener(_onAppStateChanged);
    _activationPoller?.cancel();
    super.dispose();
  }

  bool _importAsking = false;

  void _onAppStateChanged() {
    if (!mounted || _importAsking) return;
    final pending = AppStateNotifier.instance?.takePendingKeyImport();
    if (pending != null) _confirmKeyImport(pending.words, pending.name);
  }

  /// "You are importing the keys for <name>" → import → show the twelve words
  /// and ask to write them down → the activation check. The words came from a
  /// QR made by the claim page; the account already exists on chain.
  Future<void> _confirmKeyImport(String words, String name) async {
    _importAsking = true;
    try {
      // Let a load in flight finish, so the pending-key check below is true.
      while (mounted && _isLoadingData) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!mounted) return;
      if (_hasTemporaryKeys) {
        _showSnackBar(context.l10n.importKeyLinkPendingExists);
        return;
      }
      final accepted = await showImportKeyLinkDialog(context, name: name);
      if (accepted != true || !mounted) return;
      await _importFromMnemonic(words);
      if (!mounted || !_hasTemporaryKeys) return;
      await showSecretRevealDialog(
        context,
        title: context.l10n.selectAccountScreenRecoveryPhraseTitle,
        warning: context.l10n.newKeyFlowWordsWarning,
        secret: words,
        subtitle: name,
      );
      await _pollActivation();
    } finally {
      _importAsking = false;
    }
  }

  /// "I don't have a friend on PublicOS": open the claim page with this
  /// device's signed claim after `#c=` (browsers never send that part to a
  /// server). The claim is signed again for three hours, because the page
  /// checks an email and may keep the request in line; the pending card's QR
  /// then shows the same, longer claim. The poller signs in once the account
  /// exists.
  Future<void> _openClaimPage() async {
    try {
      final saved = await PublicOSAccounts.loadTemporaryLinkClaim();
      if (saved == null || saved.kind != ConsentKind.newAccount) return;
      final claim = await PublicOSAccounts.signTemporaryLinkClaim(
        kind: ConsentKind.newAccount,
        displayName: saved.input,
        validFor: const Duration(hours: 3),
      );
      final ok = await launchUrl(
        Uri.parse('$_claimPageUrl#c=${claim.consentUri}'),
        mode: LaunchMode.externalApplication,
      );
      if (!ok && mounted) _showSnackBar(context.l10n.newAccountAskOpenFailed);
    } catch (e) {
      print('Error opening the claim page: $e');
      if (mounted) _showSnackBar(context.l10n.newAccountAskOpenFailed);
    }
  }

  /// The public beta's claim door (publicos_claim). A test build can point at
  /// a door on the LAN: `--dart-define=CLAIM_PAGE_URL=http://<pc>:8092/`.
  static const String _claimPageUrl = String.fromEnvironment(
    'CLAIM_PAGE_URL',
    defaultValue: 'https://claim.publicos.dev/',
  );

  Future<void> _pollActivation() async {
    if (!mounted || !_hasTemporaryKeys || _isProcessingAction || _polling) return;
    _polling = true;
    try {
      final account =
          await PublicOSAccounts.checkAndActivatePendingTemporarySession();
      if (account != null && mounted) {
        _showSnackBar(context.l10n.selectAccountScreenKeysActivated);
        await _loadData();
      }
    } catch (_) {
      // Not linked yet, or the chain didn't answer: try again next tick.
    } finally {
      _polling = false;
    }
  }

  /// Intent → inputs → recovery words → signed claim, then the QR at once.
  Future<void> _startNewKeyFlow(NewKeyIntent intent) async {
    final address = await showNewKeyFlowDialog(context, intent: intent);
    if (!mounted) return;
    await _loadData();
    if (address == null || !mounted) return;
    // A new account needs a citizen to create it. Ask before the QR: a friend
    // scans it, or the claim page creates the account. Closing the question
    // leaves the pending card, whose QR button is still there.
    if (intent == NewKeyIntent.newAccount) {
      final help = await showNewAccountAskDialog(context);
      if (!mounted || help == null) return;
      if (help) {
        await _openClaimPage();
        return;
      }
    }
    _showTempKeyQR(address);
  }

  void _setBootStatus(String message) {
    if (!mounted) return;
    setState(() => _bootStatus = message);
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() => _isLoadingData = true);
    try {
      final accounts = await PublicOSAccounts.getStoredAccountNames();
      final hasTemp = await PublicOSAccounts.doesTemporarySessionExist();
      String? tempAddress;
      int? tempClaimDeadline;
      if (hasTemp) {
        tempAddress = await PublicOS.secureStorage
            .read(key: 'temporaryAccountSessionAddress');
        final claimRaw = await PublicOS.secureStorage
            .read(key: 'account_temporaryAccount_signed_claim');
        if (claimRaw != null) {
          try {
            tempClaimDeadline =
                (jsonDecode(claimRaw) as Map<String, dynamic>)['deadline']
                    as int?;
          } catch (_) {/* corrupt claim — no chip */}
        }
      }

      // Get the last used account address
      final lastUsedAddress = await PublicOS.secureStorage
          .read(key: 'selected_contactos_AccountAddress');

      final Map<String, Contact> contacts = {};
      for (final entry in accounts.entries) {
        final displayName = entry.key;
        final address = entry.value;

        try {
          // Local-only on this logged-out picker — on-chain enrichment is
          // commented out below.
          // Pre-login there's no ACTIVE session, so the normal getContact (which
          // scopes to sessionBlockchainAddress) returns null and every
          // fetchContact would hit the network SEQUENTIALLY, blocking the whole list
          // behind ~8-10 round-trips/account purely for cosmetics (banner / NFT
          // avatar / sparkle / phantom badge).
          //
          // Instead we read each account's OWN cached self-contact straight
          // from the local DB, scoped to that account's OWN session address (in
          // secure storage). That row was saved enriched at this account's last
          // login, so we get its avatar/banner/badges with no network and no
          // active session. getContactForAccountPicker is picker-only by design.
          final sessionHex = await PublicOS.secureStorage
              .read(key: 'account_${address.eip55With0x}_sessionAddress');
          Contact? contact = sessionHex != null
              ? await PublicOSContacts.getContactForAccountPicker(
                  address, EthereumAddress.fromHex(sessionHex))
              : null;
          // if (contact == null || contact.records.isEmpty) {
          //   try {
          //     contact = await PublicOSContacts.fetchContact(address);
          //   } catch (e) {
          //     print('[SELECT_ACCOUNT] Chain fetch failed for $displayName: $e');
          //   }
          // }
          contacts[displayName] = contact ?? Contact(
            displayName: displayName,
            publicosDisplayName: displayName,
            publicosAddress: address,
          );
        } catch (e) {
          print('[SELECT_ACCOUNT] Error loading contact for $displayName: $e');
          contacts[displayName] = Contact(
            displayName: displayName,
            publicosDisplayName: displayName,
            publicosAddress: address,
          );
        }
      }

      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _accountContacts = contacts;
        _hasTemporaryKeys = hasTemp;
        _temporaryKeysAddress = tempAddress;
        _temporaryClaimDeadline = tempClaimDeadline;
        _lastUsedAccountAddress = lastUsedAddress;
        _isLoadingData = false;
      });
    } catch (e) {
      print('Error loading login data: $e');
      if (!mounted) return;
      setState(() => _isLoadingData = false);
    }
  }

  Future<void> _selectAccount(
      String displayName, EthereumAddress address) async {
    if (!mounted) return;
    setState(() {
      _isProcessingAction = true;
      _loadingAccountName = displayName;
      _bootStatus = BootPhase.restoringSession.name;
    });
    try {
      // The boot steps live in one place — AppInitializer.runBoot — shared
      // with auto-login. This screen's only job is to hand it the tapped
      // account + a status sink (_setBootStatus is mounted-guarded). runBoot
      // fires setAccountSelected itself on success; GoRouter then redirects
      // away, so we keep the loading state. On failure it returns false.
      final appState = AppStateNotifier.instance;
      if (appState == null) {
        if (!mounted) return;
        setState(() {
          _isProcessingAction = false;
          _loadingAccountName = null;
        });
        return;
      }
      final ok = await AppInitializer(appState)
          .runBoot(address, onStatus: _setBootStatus);
      if (!ok) {
        if (!mounted) return;
        _showSnackBar(context.l10n.selectAccountScreenRestoreSessionFailed);
        setState(() {
          _isProcessingAction = false;
          _loadingAccountName = null;
        });
      }
    } catch (e) {
      print('Error selecting account: $e');
      if (!mounted) return;
      _snackError(e, fallback: (l) => l.errSelectAccountFailed);
      setState(() {
        _isProcessingAction = false;
        _loadingAccountName = null;
      });
    }
  }

  /// Localize a caught error and show it via [_showSnackBar]. Sync method, so
  /// async catch sites stay free of use_build_context_synchronously.
  void _snackError(Object e, {String Function(AppLocalizations)? fallback}) {
    if (!mounted) return;
    final l10n = context.l10n;
    _showSnackBar(localizedError(l10n, e, fallback: fallback?.call(l10n)));
  }

  void _showSnackBar(String message) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.onSurface,
          ),
        ),
        backgroundColor:
            isDark ? PhigitalStyle.cardBackgroundDark : ThemeProvider.slateDarkest,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: 0,
      ),
    );
  }

  void _showImportSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ImportKeySheet(
        title: context.l10n.selectAccountScreenImportKeyTitle,
        subtitle: context.l10n.selectAccountScreenImportKeySubtitle,
        onImportMnemonic: (mnemonic) async {
          await _importFromMnemonic(mnemonic);
          return true;
        },
        onImportPrivateKey: (privateKey) async {
          await _importFromPrivateKey(privateKey);
          return true;
        },
      ),
    );
  }

  Future<void> _importFromMnemonic(String mnemonicText) async {
    if (mnemonicText.isEmpty) {
      _showSnackBar(context.l10n.selectAccountScreenEnterMnemonic);
      return;
    }

    if (!mounted) return;
    setState(() => _isProcessingAction = true);

    try {
      final keyData =
          await PublicOSKeychain.importTemporaryBlockchainKeyFromMnemonic(
              mnemonicText);
      final address = keyData['address'] as String;

      await PublicOSKeychain.loadTemporaryBlockchainKey();

      if (!mounted) return;
      setState(() {
        _hasTemporaryKeys = true;
        _temporaryKeysAddress = address;
      });
      await _loadData();

      if (!mounted) return;
      _showSnackBar(context.l10n.selectAccountScreenKeyImported);
    } catch (e) {
      print('Error importing from mnemonic: $e');
      if (!mounted) return;
      _snackError(e, fallback: (l) => l.errImportFailed);
    } finally {
      if (!mounted) return;
      setState(() => _isProcessingAction = false);
    }
  }

  Future<void> _importFromPrivateKey(String privateKeyHexText) async {
    if (privateKeyHexText.isEmpty) {
      _showSnackBar(context.l10n.selectAccountScreenEnterPrivateKey);
      return;
    }

    if (!mounted) return;
    setState(() => _isProcessingAction = true);

    try {
      final keyData =
          await PublicOSKeychain.importTemporaryBlockchainKeyFromPrivateKey(
              privateKeyHexText);
      final address = keyData['address'] as String;

      await PublicOSKeychain.loadTemporaryBlockchainKey();

      if (!mounted) return;
      setState(() {
        _hasTemporaryKeys = true;
        _temporaryKeysAddress = address;
      });
      await _loadData();

      if (!mounted) return;
      _showSnackBar(context.l10n.selectAccountScreenKeyImported);
    } catch (e) {
      print('Error importing from private key: $e');
      if (!mounted) return;
      _snackError(e, fallback: (l) => l.errImportFailed);
    } finally {
      if (!mounted) return;
      setState(() => _isProcessingAction = false);
    }
  }

  Future<void> _checkAndActivate() async {
    if (!mounted) return;
    setState(() => _isProcessingAction = true);
    try {
      final accountAddressHex =
          await PublicOSAccounts.checkAndActivatePendingTemporarySession();

      if (accountAddressHex != null) {
        if (!mounted) return;
        _showSnackBar(context.l10n.selectAccountScreenKeysActivated);
        await _loadData();
      } else {
        if (!mounted) return;
        _showSnackBar(context.l10n.selectAccountScreenKeysNotLinked);
      }
    } catch (e) {
      print('Error checking activation: $e');
      if (!mounted) return;
      _snackError(e, fallback: (l) => l.errCheckActivationFailed);
    } finally {
      if (!mounted) return;
      setState(() => _isProcessingAction = false);
    }
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    _showSnackBar(context.l10n.selectAccountScreenAddressCopied);
  }

  /// Open the Link Device dialog — the new-device side of the
  /// client_consent_signatures cross-device flow. Generates an EIP-712
  /// consent locally with the temp key, encodes it as a `publicos-claim:`
  /// URI inside a `publicos://` deep-link wrapper, renders the QR with a
  /// 1h countdown + refresh-on-expire affordance.
  void _showTempKeyQR(String address) {
    // Reload on close so a freshly-signed (or refreshed) claim's countdown
    // surfaces on the pending card immediately.
    showLinkDeviceDialog(context, tempAddress: address).then((_) {
      if (mounted) _loadData();
    });
  }

  // Legacy QR dialog (kept commented out for reference until the new
  // link_device_dialog has device-test coverage).
  // ignore: unused_element
  void _showTempKeyQRLegacy(String address) {
    bool isAddSession = true;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final tokens = GlassTokens.of(context);
          final qrData = isAddSession
              ? 'publicos://add_session/$address'
              : 'publicos://new_account/$address';

          return Dialog(
            constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
            backgroundColor: Colors.transparent,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                child: Container(
                  padding: const EdgeInsets.all(28),
                  decoration: GlassTheme.glassBox(context).copyWith(
                    color: tokens.surfaceDeep.withValues(alpha: 0.9),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.qr_code_2,
                        color: tokens.starkWhite,
                        size: 28,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        context.l10n.selectAccountScreenLinkDeviceTitle,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 3,
                          color: tokens.starkWhite,
                        ),
                      ),
                      const SizedBox(height: 20),
                      // Mode toggle
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: tokens.borderSubtle),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () =>
                                    setDialogState(() => isAddSession = true),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isAddSession
                                        ? tokens.starkWhite
                                            .withValues(alpha: 0.12)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    context.l10n.selectAccountScreenAddSession,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.5,
                                      color: isAddSession
                                          ? tokens.starkWhite
                                          : tokens.textDim,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: GestureDetector(
                                onTap: () =>
                                    setDialogState(() => isAddSession = false),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: !isAddSession
                                        ? tokens.starkWhite
                                            .withValues(alpha: 0.12)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    context.l10n.selectAccountScreenNewAccount,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.5,
                                      color: !isAddSession
                                          ? tokens.starkWhite
                                          : tokens.textDim,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isAddSession
                            ? context.l10n.selectAccountScreenScanAuthorizeKey
                            : context.l10n.selectAccountScreenScanCreateAccount,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: tokens.textDim,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 24),
                      // QR Code — light dots on dark glass
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: tokens.surfaceDeep,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: tokens.borderSubtle),
                          boxShadow: [
                            BoxShadow(
                              color:
                                  tokens.starkWhite.withValues(alpha: 0.08),
                              blurRadius: 30,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: QrImageView(
                          data: qrData,
                          version: QrVersions.auto,
                          size: 180,
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
                      const SizedBox(height: 20),
                      GestureDetector(
                        onTap: () => _copyToClipboard(address),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: tokens.borderSubtle),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  address,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    color: tokens.textDim,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                Icons.copy,
                                size: 14,
                                color: tokens.textDim,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: tokens.starkWhite,
                            foregroundColor: tokens.background,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onPressed: () => Navigator.pop(context),
                          child: Text(
                            context.l10n.selectAccountScreenDone,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Pushes the full-screen profile QR page for a verified account.
  void _openProfileQR(String address, Contact contact, String displayName) {
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => ProfileQrPage(
          address: address,
          contact: contact,
          displayName: displayName,
        ),
      ),
    );
  }

  /// Delete a real account from THIS DEVICE — keys, messages, contacts,
  /// settings. The on-chain account is untouched and can be re-imported with
  /// its recovery phrase / private key. Local-only wipe via
  /// [PublicOSAccounts.deleteStoredAccounts] plus the on-disk libxmtp MLS
  /// database (keyed by the account's session signing address, resolved here
  /// before deleteStoredAccounts wipes the secret that holds it). Picker-screen
  /// only — Core blocks deleting the active account, which never applies here
  /// (nothing is logged in on this screen).
  Future<void> _deleteAccount(
      String displayName, EthereumAddress address) async {
    final errorColor = Theme.of(context).colorScheme.error;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final tokens = GlassTokens.of(context);
        return Dialog(
          constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
          backgroundColor: Colors.transparent,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: GlassTheme.glassBox(context).copyWith(
                  color: tokens.surfaceDeep.withValues(alpha: 0.9),
                  border: Border.all(color: errorColor.withValues(alpha: 0.4)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: errorColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.delete_outline,
                            color: errorColor,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            context.l10n.selectAccountScreenDeleteAccountTitle,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2,
                              color: tokens.starkWhite,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      context.l10n
                          .selectAccountScreenDeleteAccountBody(displayName),
                      style: TextStyle(
                        fontSize: 13,
                        color: tokens.starkWhite,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      context.l10n.selectAccountScreenDeleteAccountNote,
                      style: TextStyle(
                        fontSize: 13,
                        color: tokens.textDim,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: _buildDialogButton(
                            tokens: tokens,
                            label: context.l10n.actionCancel,
                            onTap: () => Navigator.of(context).pop(false),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _buildDialogButton(
                            tokens: tokens,
                            label: context.l10n.selectAccountScreenDelete,
                            onTap: () => Navigator.of(context).pop(true),
                            background: errorColor,
                            foreground: tokens.starkWhite,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    if (confirmed != true) return;

    if (!mounted) return;
    setState(() => _isProcessingAction = true);

    try {
      // Resolve the session (signing) address BEFORE the wipe — it keys the
      // on-disk libxmtp MLS database, and deleteStoredAccounts removes the
      // secret that holds it. Best-effort: an orphan .db3 is harmless once its
      // DB key is gone, so a failure here never blocks the delete.
      final sessionHex = await PublicOS.secureStorage
          .read(key: 'account_${address.eip55With0x}_sessionAddress');
      if (sessionHex != null && sessionHex.isNotEmpty) {
        await PublicOSKeychain.deleteLocalXmtpDatabase(sessionHex);
      }

      final ok = await PublicOSAccounts.deleteStoredAccounts(address);
      if (!mounted) return;
      if (ok) {
        _showSnackBar(context.l10n.selectAccountScreenAccountRemoved);
        await _loadData();
      } else {
        _showSnackBar(context.l10n.selectAccountScreenDeleteAccountFailed);
      }
    } catch (e) {
      print('Error deleting account: $e');
      if (!mounted) return;
      _snackError(e, fallback: (l) => l.errDeleteAccountFailed);
    } finally {
      if (!mounted) return;
      setState(() => _isProcessingAction = false);
    }
  }

  Future<void> _deleteTemporaryKeys() async {
    final errorColor = Theme.of(context).colorScheme.error;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final tokens = GlassTokens.of(context);
        return Dialog(
          constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
          backgroundColor: Colors.transparent,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: GlassTheme.glassBox(context).copyWith(
                  color: tokens.surfaceDeep.withValues(alpha: 0.9),
                  border: Border.all(color: errorColor.withValues(alpha: 0.4)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: errorColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.delete_outline,
                            color: errorColor,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          context.l10n.selectAccountScreenDeleteKeyPairTitle,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2,
                            color: tokens.starkWhite,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      context.l10n.selectAccountScreenDeleteKeyPairBody,
                      style: TextStyle(
                        fontSize: 13,
                        color: tokens.textDim,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: _buildDialogButton(
                            tokens: tokens,
                            label: context.l10n.actionCancel,
                            onTap: () => Navigator.of(context).pop(false),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _buildDialogButton(
                            tokens: tokens,
                            label: context.l10n.selectAccountScreenDelete,
                            onTap: () => Navigator.of(context).pop(true),
                            background: errorColor,
                            foreground: tokens.starkWhite,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    if (confirmed != true) return;

    if (!mounted) return;
    setState(() => _isProcessingAction = true);

    try {
      final success = await PublicOSKeychain.deleteTemporaryBlockchainKey();

      if (success) {
        if (!mounted) return;
        _showSnackBar(context.l10n.selectAccountScreenKeyPairDeleted);
        await _loadData();
      } else {
        if (!mounted) return;
        _showSnackBar(context.l10n.selectAccountScreenDeleteKeyPairFailed);
      }
    } catch (e) {
      print('Error deleting key pair: $e');
      if (!mounted) return;
      _snackError(e, fallback: (l) => l.errDeleteKeyPairFailed);
    } finally {
      if (!mounted) return;
      setState(() => _isProcessingAction = false);
    }
  }

  Future<void> _resetApp() async {
    final errorColor = Theme.of(context).colorScheme.error;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final tokens = GlassTokens.of(context);
        return Dialog(
          constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
          backgroundColor: Colors.transparent,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: GlassTheme.glassBox(context).copyWith(
                  color: tokens.surfaceDeep.withValues(alpha: 0.9),
                  border: Border.all(color: errorColor.withValues(alpha: 0.4)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: errorColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.warning_amber_rounded,
                            color: errorColor,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          context.l10n.selectAccountScreenResetAppTitle,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2,
                            color: tokens.starkWhite,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      context.l10n.selectAccountScreenResetAppHeading,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: tokens.starkWhite,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _buildResetListItem(tokens, errorColor,
                        context.l10n.selectAccountScreenResetItemMessages),
                    _buildResetListItem(tokens, errorColor,
                        context.l10n.selectAccountScreenResetItemContacts),
                    _buildResetListItem(tokens, errorColor,
                        context.l10n.selectAccountScreenResetItemKeys),
                    _buildResetListItem(tokens, errorColor,
                        context.l10n.selectAccountScreenResetItemFeeds),
                    _buildResetListItem(tokens, errorColor,
                        context.l10n.selectAccountScreenResetItemDatabases),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: errorColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              color: errorColor, size: 16),
                          const SizedBox(width: 8),
                          Text(
                            context.l10n.selectAccountScreenCannotBeUndone,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: errorColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: _buildDialogButton(
                            tokens: tokens,
                            label: context.l10n.actionCancel,
                            onTap: () => Navigator.of(context).pop(false),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _buildDialogButton(
                            tokens: tokens,
                            label: context.l10n.selectAccountScreenReset,
                            onTap: () => Navigator.of(context).pop(true),
                            background: errorColor,
                            foreground: tokens.starkWhite,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    if (confirmed != true) return;

    if (!mounted) return;
    setState(() => _isProcessingAction = true);

    try {
      // Snapshot the wallet addresses BEFORE we wipe secure storage — the
      // account list is gone after deleteAll(). Includes any pending temp key.
      final walletAddresses = <String>{
        for (final addr in _accounts.values) addr.eip55With0x,
        if (_temporaryKeysAddress != null) _temporaryKeysAddress!,
      };

      // Full nuke: every Drift table, not just messages + contacts. The
      // Conversations table in particular caches `inbox id -> topic`; leaving
      // it behind is what let a stale (dead) MLS topic survive a chain reset.
      await PublicOS.database.transaction(() async {
        await PublicOS.database.delete(PublicOS.database.messages).go();
        await PublicOS.database.delete(PublicOS.database.contacts).go();
        await PublicOS.database.delete(PublicOS.database.conversations).go();
        await PublicOS.database.delete(PublicOS.database.settings).go();
        await PublicOS.database.delete(PublicOS.database.feedServers).go();
        await PublicOS.database.delete(PublicOS.database.rpcServers).go();
        await PublicOS.database.delete(PublicOS.database.feedLists).go();
        await PublicOS.database.delete(PublicOS.database.listFeeds).go();
        await PublicOS.database.delete(PublicOS.database.attachmentCache).go();
        await PublicOS.database.delete(PublicOS.database.bookmarkedApps).go();
        await PublicOS.database.delete(PublicOS.database.bookmarkedPosts).go();
      });

      // Delete the on-disk libxmtp MLS databases so stale group state can't
      // re-materialize. Best-effort per address (non-throwing in Core).
      for (final address in walletAddresses) {
        await PublicOSKeychain.deleteLocalXmtpDatabase(address);
      }

      await PublicOS.secureStorage.deleteAll();

      if (!mounted) return;
      _showSnackBar(context.l10n.selectAccountScreenAppResetComplete);
      await _loadData();
    } catch (e) {
      print('Error resetting app: $e');
      if (!mounted) return;
      _snackError(e, fallback: (l) => l.errResetAppFailed);
    } finally {
      if (!mounted) return;
      setState(() => _isProcessingAction = false);
    }
  }

  Widget _buildResetListItem(
      GlassTokens tokens, Color bulletColor, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              color: bulletColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            text,
            style: TextStyle(fontSize: 13, color: tokens.textDim),
          ),
        ],
      ),
    );
  }

  Widget _buildDialogButton({
    required GlassTokens tokens,
    required String label,
    required VoidCallback onTap,
    Color? background,
    Color? foreground,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 42,
        decoration: BoxDecoration(
          color: background ?? tokens.glassFillHover,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
              color: foreground ?? tokens.starkWhite,
            ),
          ),
        ),
      ),
    );
  }

  /// Builds an ID badge card for an account
  Widget _buildIdBadge({
    required ThemeData theme,
    required String displayName,
    required String address,
    required Contact contact,
    required bool isLoading,
    required VoidCallback onTap,
    VoidCallback? onDelete,
    bool isPending = false,
    bool isLastUsed = false,
  }) {
    final tokens = GlassTokens.of(context);
    final shortAddress =
        '${address.substring(0, 6)}...${address.substring(address.length - 4)}';

    // Only last-used accounts get an emphasis border. Pending keys are
    // signalled by the PENDING badge + CHECK ACTIVATION button, not the
    // outer border — matches the verified-card look.
    final emphasisColor = isLastUsed ? tokens.connectedAccent : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: isPending || isLoading || _isProcessingAction
                  ? null
                  : onTap,
              child: Container(
                clipBehavior: Clip.antiAlias,
                // Borderless card: the glassBox subtle outline is dropped;
                // only the last-used card has an accent ring, as a state
                // signal.
                decoration: GlassTheme.glassBox(context).copyWith(
                  border: emphasisColor != null
                      ? Border.all(
                          color: emphasisColor.withValues(alpha: 0.5),
                          width: 1.5,
                        )
                      : const Border.fromBorderSide(BorderSide.none),
                ),
                child: Column(
                  children: [
                    // Banner with avatar + name + address overlay
                    SizedBox(
                      height: 88,
                      width: double.infinity,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // NFT banner first ([ContactBanner]). Costs no round
                          // trip: this picker reads each account's cached
                          // self-contact, enriched at its last login, so the
                          // NFT verdict is already in the row.
                          ContactBanner(
                            contact: contact,
                            fallback: _bannerFallback(tokens, contact),
                          ),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.black.withValues(alpha: 0.15),
                                  Colors.black.withValues(alpha: 0.65),
                                ],
                              ),
                            ),
                          ),
                          Positioned(
                            left: 16,
                            right: 16,
                            bottom: 10,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                GlassContactIcon(
                                  contact: contact,
                                  address: address,
                                  size: 60,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              displayName,
                                              style: TextStyle(
                                                fontSize: 17,
                                                fontWeight: FontWeight.w700,
                                                letterSpacing: 0.5,
                                                color: tokens.starkWhite,
                                                shadows: const [
                                                  Shadow(
                                                    color: Colors.black54,
                                                    blurRadius: 6,
                                                  ),
                                                ],
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          // PENDING only when a signed claim
                                          // is saved; RECENT always.
                                          if ((isPending &&
                                                  _temporaryClaimDeadline !=
                                                      null) ||
                                              isLastUsed) ...[
                                            const SizedBox(width: 8),
                                            Builder(builder: (_) {
                                              final badgeColor = isPending
                                                  ? tokens.fallbackAccent
                                                  : tokens.connectedAccent;
                                              return Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 7,
                                                  vertical: 2,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: badgeColor.withValues(
                                                      alpha: 0.18),
                                                  border: Border.all(
                                                    color: badgeColor
                                                        .withValues(alpha: 0.5),
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(5),
                                                ),
                                                child: Text(
                                                  isPending
                                                      ? context.l10n
                                                          .selectAccountScreenBadgePending
                                                      : context.l10n
                                                          .selectAccountScreenBadgeRecent,
                                                  style: TextStyle(
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.w800,
                                                    letterSpacing: 1,
                                                    color: badgeColor,
                                                  ),
                                                ),
                                              );
                                            }),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        shortAddress,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontFamily: 'monospace',
                                          color: tokens.starkWhite,
                                          shadows: const [
                                            Shadow(
                                              color: Colors.black54,
                                              blurRadius: 6,
                                            ),
                                          ],
                                        ),
                                      ),
                                      // An expiring key counts down here;
                                      // permanent: nothing.
                                      if (!isPending)
                                        KeyLifetimeLine(accountAddress: address),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Garbage button — delete this account locally from
                          // the device. Real accounts only (pending temp keys
                          // keep their own Remove in the action bar). Its own
                          // tap absorbs the card's login InkWell.
                          if (onDelete != null && !isPending)
                            Positioned(
                              top: 6,
                              right: 6,
                              child: Tooltip(
                                message: context
                                    .l10n.selectAccountScreenDeleteFromDevice,
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap:
                                        _isProcessingAction ? null : onDelete,
                                    borderRadius: BorderRadius.circular(8),
                                    child: Container(
                                      width: 30,
                                      height: 30,
                                      decoration: BoxDecoration(
                                        color:
                                            Colors.black.withValues(alpha: 0.4),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Icon(
                                        Icons.delete_outline_rounded,
                                        size: 16,
                                        color: tokens.starkWhite,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),

                    // Action bar — QR/Copy left, Login/Remove right
                    Padding(
                      padding:
                          const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildSlimIconAction(
                              tokens: tokens,
                              icon: Icons.qr_code_2_rounded,
                              tooltip: context.l10n.selectAccountScreenShowQr,
                              onTap: _isProcessingAction
                                  ? null
                                  : () => isPending
                                      ? _showTempKeyQR(address)
                                      : _openProfileQR(
                                          address, contact, displayName),
                            ),
                            const SizedBox(width: 6),
                            _buildSlimIconAction(
                              tokens: tokens,
                              icon: Icons.copy_rounded,
                              tooltip:
                                  context.l10n.selectAccountScreenCopyAddress,
                              onTap: _isProcessingAction
                                  ? null
                                  : () => _copyToClipboard(address),
                            ),
                            if (isPending &&
                                _temporaryClaimDeadline != null) ...[
                              const SizedBox(width: 6),
                              _ClaimCountdownChip(
                                tokens: tokens,
                                deadline: _temporaryClaimDeadline!,
                              ),
                            ],
                            const Spacer(),
                            if (isPending)
                              _buildSlimIconAction(
                                tokens: tokens,
                                icon: Icons.delete_outline_rounded,
                                tooltip: context.l10n.selectAccountScreenRemove,
                                onTap: _isProcessingAction
                                    ? null
                                    : _deleteTemporaryKeys,
                              )
                            else if (isLoading)
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 8),
                                child: Center(
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                ),
                              )
                            else
                              _buildCardAction(
                                tokens: tokens,
                                icon: Icons.login_rounded,
                                label: context.l10n.selectAccountScreenLogin,
                                onTap:
                                    _isProcessingAction ? null : onTap,
                                isPrimary: true,
                              ),
                          ],
                        ),
                      ),
                    ),

                    // Activation button for pending keys
                    if (isPending && !isLoading)
                      Padding(
                        padding:
                            const EdgeInsets.fromLTRB(10, 0, 10, 10),
                        child: SizedBox(
                          width: double.infinity,
                          child: _buildCardAction(
                            tokens: tokens,
                            icon: Icons.check_circle_outline_rounded,
                            label:
                                context.l10n.selectAccountScreenCheckActivation,
                            onTap: _isProcessingAction
                                ? null
                                : _checkAndActivate,
                            isPrimary: true,
                            stretch: true,
                          ),
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

  Widget _bannerFallback(GlassTokens tokens, Contact contact) {
    final base = contact.iconColor;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [base.withValues(alpha: 0.25), tokens.surfaceDeep],
        ),
      ),
    );
  }

  Widget _buildCardAction({
    required GlassTokens tokens,
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    bool isPrimary = false,
    bool stretch = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isPrimary
              ? tokens.starkWhite.withValues(alpha: 0.14)
              : tokens.glassFillHover,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: stretch ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: tokens.starkWhite, size: 14),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
                color: tokens.starkWhite,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlimIconAction({
    required GlassTokens tokens,
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: AspectRatio(
          aspectRatio: 1,
          child: Container(
            padding: const EdgeInsets.all(6),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tokens.glassFillHover,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, color: tokens.starkWhite, size: 16),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;

    return Column(
      children: [
        const SizedBox(height: 32),
        // Empty ID badge placeholder
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.05)
                : ThemeProvider.slateDarkest.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.1)
                  : ThemeProvider.slateDarkest.withValues(alpha: 0.08),
              width: 1.5,
              strokeAlign: BorderSide.strokeAlignInside,
            ),
          ),
          child: Icon(
            Icons.badge_outlined,
            size: 32,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          context.l10n.selectAccountScreenNoIdentitiesTitle,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          context.l10n.selectAccountScreenNoIdentitiesSubtitle,
          style: TextStyle(
            fontSize: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 28),
      ],
    );
  }

  Widget _buildActionButtons(ThemeData theme) {
    return Column(
      children: [
        // New-key flow: intent first. Both buttons hide while
        // a pending key exists (one account at a time).
        _buildActionButton(
          icon: Icons.devices_rounded,
          label: context.l10n.newKeyFlowAddDevice,
          onTap: _isProcessingAction
              ? null
              : () => _startNewKeyFlow(NewKeyIntent.addDevice),
        ),
        const SizedBox(height: 12),
        _buildActionButton(
          icon: Icons.person_add_alt_1_rounded,
          label: context.l10n.newKeyFlowNewAccount,
          onTap: _isProcessingAction
              ? null
              : () => _startNewKeyFlow(NewKeyIntent.newAccount),
        ),
        const SizedBox(height: 12),
        _buildActionButton(
          icon: Icons.key,
          label: context.l10n.selectAccountScreenImportKeyButton,
          onTap: _isProcessingAction ? null : _showImportSheet,
          isSubtle: true,
        ),
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    bool isSubtle = false,
  }) {
    final tokens = GlassTokens.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            color: isSubtle
                ? tokens.glassFill
                : tokens.starkWhite.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: tokens.starkWhite, size: 18),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2,
                  color: tokens.starkWhite,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Max content width for larger screens (tablet/desktop)
  static const double _maxContentWidth = 440.0;

  Widget _buildHeaderIcon({
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
  }) {
    final tokens = GlassTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: tokens.starkWhite, size: 18),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = GlassTokens.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final horizontalPadding = screenWidth > 600 ? 28.0 : 20.0;

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 40),
                      Row(
                        children: [
                          const PhigitalLoadingWidget(
                            size: 18,
                            pulse: true,
                            showShadows: false,
                          ),
                          // Wordmark: "PublicOS/client" — the system name in
                          // bold, a faint slash, then the app's role in light
                          // weight.
                          Text.rich(
                            TextSpan(
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: tokens.starkWhite,
                                letterSpacing: 1.2,
                              ),
                              children: [
                                const TextSpan(text: 'PublicOS'),
                                TextSpan(
                                  text: ' / ',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w300,
                                    color: tokens.starkWhite.withValues(alpha: 0.35),
                                    letterSpacing: 0,
                                  ),
                                ),
                                const TextSpan(
                                  text: 'client',
                                  style: TextStyle(fontWeight: FontWeight.w300),
                                ),
                              ],
                            ),
                          ),
                          const Spacer(),
                          _buildHeaderIcon(
                            icon: Icons.restart_alt,
                            tooltip: context.l10n.selectAccountScreenResetTooltip,
                            onTap: _isProcessingAction ? null : _resetApp,
                          ),
                        ],
                      ),
                      const SizedBox(height: 40),
                      Text(
                        context.l10n.selectAccountScreenIdentities,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 4,
                          color: tokens.starkWhite,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        context.l10n.selectAccountScreenSelectToAuthenticate,
                        style: TextStyle(
                          color: tokens.textDim,
                          fontSize: 12,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 48),
                      if (_isLoadingData)
                        const Expanded(
                          child: Align(
                            alignment: Alignment.bottomRight,
                            // Extra bottom inset lifts the loader ~8px above the
                            // version legend pinned in the corner so they don't
                            // overlap.
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(16, 16, 16, 24),
                              child: PixelRainLoadingWidget(size: 40),
                            ),
                          ),
                        )
                      else
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
                                if (_accounts.isEmpty && !_hasTemporaryKeys)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 24),
                                    child: Text(
                                      context.l10n
                                          .selectAccountScreenNoIdentitiesFound,
                                      style:
                                          TextStyle(color: tokens.textDim),
                                    ),
                                  ),
                                // Account cards - sorted with last used first
                                ...(_accounts.entries.toList()
                                      ..sort((a, b) {
                                        final aIsLastUsed =
                                            a.value.eip55With0x ==
                                                _lastUsedAccountAddress;
                                        final bIsLastUsed =
                                            b.value.eip55With0x ==
                                                _lastUsedAccountAddress;
                                        if (aIsLastUsed && !bIsLastUsed) {
                                          return -1;
                                        }
                                        if (!aIsLastUsed && bIsLastUsed) {
                                          return 1;
                                        }
                                        return 0;
                                      }))
                                    .map((entry) {
                                  final displayName = entry.key;
                                  final address = entry.value;
                                  final contact =
                                      _accountContacts[displayName] ??
                                          Contact(
                                            displayName: displayName,
                                            publicosDisplayName: displayName,
                                            publicosAddress: address,
                                          );
                                  final isLastUsed = address.eip55With0x ==
                                      _lastUsedAccountAddress;

                                  return _buildIdBadge(
                                    theme: theme,
                                    displayName: displayName,
                                    address: address.eip55With0x,
                                    contact: contact,
                                    isLoading:
                                        _loadingAccountName == displayName,
                                    isLastUsed: isLastUsed,
                                    onTap: () =>
                                        _selectAccount(displayName, address),
                                    onDelete: () =>
                                        _deleteAccount(displayName, address),
                                  );
                                }),

                                if (_hasTemporaryKeys &&
                                    _temporaryKeysAddress != null)
                                  _buildIdBadge(
                                    theme: theme,
                                    displayName: context
                                        .l10n.selectAccountScreenNewKeysCardName,
                                    address: _temporaryKeysAddress!,
                                    contact: Contact(
                                      displayName: 'Pending',
                                      records: [
                                        Record.asSettings(
                                          key: 'color',
                                          value: ThemeProvider.amberAccent.value
                                              .toString(),
                                          isSystem: true,
                                          expiration: DateTime.now()
                                              .add(const Duration(days: 365)),
                                          opacity: 1.0,
                                        ),
                                        Record.asSettings(
                                          key: 'profile.avatar',
                                          value:
                                              'https://feeds.publicos.dev/media/4c12b94b.1794777687.png',
                                          isSystem: true,
                                          expiration: DateTime.now()
                                              .add(const Duration(days: 365)),
                                          opacity: 1.0,
                                        ),
                                      ],
                                    ),
                                    isLoading: false,
                                    isPending: true,
                                    onTap: () {},
                                  ),

                                if (!_hasTemporaryKeys) ...[
                                  const SizedBox(height: 8),
                                  _buildActionButtons(theme),
                                ],

                                const SizedBox(height: 32),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_isProcessingAction)
            Positioned.fill(
              child: Container(
                color: tokens.background,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const PhigitalLoadingWidget(
                        size: 56,
                        pulse: true,
                        showShadows: false,
                      ),
                      const SizedBox(height: 32),
                      Text(
                        _bootStatus.isEmpty
                            ? context.l10n.bootLoading
                            : (bootPhaseLabel(context.l10n, _bootStatus) ??
                                _bootStatus),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: tokens.textDim,
                          fontSize: 13,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // Build version, bottom-right. Drawn last so it stays on top of the
          // processing overlay — the centered spinner sits above it during a
          // reset/boot. bottom: 0 inside SafeArea keeps it on-screen on every
          // device (a negative offset clipped it on shorter phones).
          const Positioned(
            right: 20,
            bottom: 0,
            child: SafeArea(
              child: Padding(
                padding: EdgeInsets.only(bottom: 4, right: 4),
                child: AppVersionLabel(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ID card style action button
class _IdActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;

  const _IdActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final color = isDestructive
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isDestructive
              ? theme.colorScheme.error.withValues(alpha: 0.1)
              : (isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : ThemeProvider.slateDarkest.withValues(alpha: 0.04)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Live countdown chip for a pending temp card's signed link-device claim.
/// Ticks once a second; green while fresh, amber under a minute, error once
/// expired. Reads the deadline (Unix seconds) the dialog persisted.
class _ClaimCountdownChip extends StatefulWidget {
  final GlassTokens tokens;
  final int deadline;
  const _ClaimCountdownChip({required this.tokens, required this.deadline});

  @override
  State<_ClaimCountdownChip> createState() => _ClaimCountdownChipState();
}

class _ClaimCountdownChipState extends State<_ClaimCountdownChip> {
  Timer? _ticker;
  int _remaining = 0;

  @override
  void initState() {
    super.initState();
    _recompute();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(_recompute);
    });
  }

  void _recompute() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _remaining = (widget.deadline - now).clamp(0, 1 << 30);
    if (_remaining <= 0) _ticker?.cancel();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = widget.tokens;
    final expired = _remaining <= 0;
    final stale = _remaining <= 60;
    final color = expired
        ? Theme.of(context).colorScheme.error
        : stale
            ? tokens.fallbackAccent
            : tokens.connectedAccent;
    final mins = (_remaining ~/ 60).clamp(0, 9999);
    final secs = (_remaining % 60).clamp(0, 59);
    final label = expired
        ? context.l10n.selectAccountScreenExpired
        : '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            expired ? Icons.timer_off_rounded : Icons.schedule_rounded,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
