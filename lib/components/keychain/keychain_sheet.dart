import 'dart:math';
import 'dart:async';

import 'package:publicos_core/publicos_core.dart';
import 'package:flutter/material.dart';
import 'package:publicos_client/components/key_lifetime_line.dart';
import 'package:flutter/services.dart';
import 'package:wallet/wallet.dart';
import 'package:web3dart/web3dart.dart' show EthPrivateKey;
import 'package:file_selector/file_selector.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:path_provider/path_provider.dart';
import 'package:publicos_client/widgets/fullscreen_overlay.dart';
import 'package:publicos_client/components/feeds/emoji_picker_dialog.dart';
import 'package:publicos_client/components/glass_contact_icon.dart';
import 'package:publicos_client/components/keychain/inbox_tab_dialog.dart';
import 'package:publicos_client/components/import_key_sheet.dart';
import 'package:publicos_client/components/secret_dialogs.dart';
import 'package:publicos_client/components/pixel_rain_loading_widget.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/router.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/l10n/app_localizations.dart';
import 'package:publicos_client/utils/favicon_utils.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';
import 'package:zero_cached_image/zero_cached_image.dart';

/// What a freshly created key carries: the label the user typed and the emoji
/// it will wear in the list.
class _NewKey {
  final String label;
  final String emoji;
  const _NewKey({required this.label, required this.emoji});
}

/// Avatars offered at key creation. The default is picked at RANDOM so keys a
/// user never bothers to personalise still tend to differ at a glance -
/// nothing keys off the emoji, so repeats are harmless.
const kKeyEmojiPool = <String>[
  '\u{1F511}', '\u{1F5DD}\u{FE0F}', '\u{1F98A}', '\u{1F419}', '\u{1F989}',
  '\u{1F41D}', '\u{1F988}', '\u{1F422}', '\u{1F981}', '\u{1F43C}',
  '\u{1F340}', '\u{1F335}', '\u{1F30A}', '\u{1F525}', '\u{26A1}',
  '\u{1F308}', '\u{1F319}', '\u{2B50}', '\u{1F355}', '\u{1F344}',
  '\u{1F3B2}', '\u{1F3B8}', '\u{1F3BA}', '\u{1F9ED}', '\u{1F6F8}',
  '\u{1F680}', '\u{26F5}', '\u{1F3D4}\u{FE0F}', '\u{1F9CA}', '\u{1FA90}',
];

String randomKeyEmoji() =>
    kKeyEmojiPool[Random.secure().nextInt(kKeyEmojiPool.length)];



/// Which "current key" pointer the sheet surfaces as the quick action on
/// each row. Both selections live in `PublicOSKeychain` independently;
/// the sheet is the same, only the emphasized action rotates.
enum KeychainType { xmtp, web }

/// Onboarding restrictions for the keychain sheet:
///  - off:      normal keychain (default; every action available).
///  - create:   "create your first key" — only Generate is shown (Import
///              hidden); a freshly generated key is NOT auto-loaded into XMTP and
///              the per-key "use for XMTP" (SIM) action is disabled. The user
///              activates a key later, on the XMTP step.
///  - activate: "start XMTP with a key" — Generate + Import hidden; the per-key
///              SIM action is the only thing enabled, to load a key into XMTP.
///  - tour:     the doing-tour's coach sequence — Generate visible, Import
///              hidden, generate does NOT auto-load, and the SIM stays LIVE.
///              `create` and `activate` are two halves of the same walk, split
///              across two pages by the old onboarding; the coach sequence runs
///              both halves inside ONE open sheet (generate, then tap the SIM on
///              the key that just appeared), so it needs the union: everything
///              `create` allows, plus the SIM that `create` disables.
///              **The split is deliberately preserved rather than collapsed** —
///              the app's normal Generate auto-loads into XMTP, which would do
///              the whole job in one tap, but then the SIM icon is never taught
///              and a user with several keys has no idea how to switch between
///              them.
enum KeychainOnboardingMode { off, create, activate, tour }

/// The user's choice when a key is not yet set up for XMTP on this device.
enum _XmtpSetupChoice { createFresh, restore, restoreSsp }

class KeychainSheet extends StatefulWidget {
  final EthereumAddress? orgAddress;
  final String? groupName;
  final VoidCallback? onKeysChanged;

  /// Controls which quick-action button appears on the right of each row
  /// (left of the expand chevron). `xmtp` → "set as current XMTP key",
  /// `web` → "set as current web/signing key". Every other action lives
  /// inside the expanded drawer regardless of type.
  final KeychainType type;

  /// Onboarding restriction mode (see [KeychainOnboardingMode]). Default off —
  /// no change for existing callers.
  final KeychainOnboardingMode onboardingMode;

  /// Coach anchors. The doing-tour spotlights two controls that live *inside*
  /// this sheet, and a spotlight needs a rect to measure — so the tour hands
  /// down the keys and the sheet attaches them. Null everywhere else, which is
  /// every caller but the tour: an unattached key changes nothing.
  ///
  /// Passing keys in beats reaching for the widgets from outside: the sheet
  /// stays the only thing that knows where its own buttons are, and it says so
  /// in the two lines that attach them.
  final GlobalKey? tourGenerateKey;
  final GlobalKey? tourSimKey;

  /// The title and the session key row, for the tour's house beat, which
  /// spotlights both at once before GENERATE.
  final GlobalKey? tourTitleKey;
  final GlobalKey? tourSessionKey;

  const KeychainSheet({
    super.key,
    this.orgAddress,
    this.groupName,
    this.onKeysChanged,
    this.type = KeychainType.xmtp,
    this.onboardingMode = KeychainOnboardingMode.off,
    this.tourGenerateKey,
    this.tourSimKey,
    this.tourTitleKey,
    this.tourSessionKey,
  });

  bool get isGroupContext => orgAddress != null;

  /// Setting key for the publish-this-inbox offer (local drift, scoped per
  /// account by PublicOSSettings' own (key, sessionAddress) keying).
  /// `'true'` = the user asked us to stop offering.
  ///
  /// Public and on the WIDGET, not the state, so the Settings app's XMTP
  /// section can name the same key rather than duplicate the string — one
  /// setting, two surfaces, no chance of them drifting apart.
  static const String kInboxPromptOffKey = 'xmtp_inbox_register_never_ask';

  /// Per-key "Keep private": the offer's left button. Stored as
  /// `<prefix><inboxId>` = 'true', local, so that key's inbox is not offered
  /// again. The manual publish row is untouched by it.
  static const String kInboxKeepPrivatePrefix = 'xmtp_inbox_keep_private:';

  @override
  State<KeychainSheet> createState() => _KeychainSheetState();
}

/// The name a first inbox gets when nothing else claims it. It matches the
/// label used when a profile is published unattended, so a profile published
/// by hand and one published by tooling end up wearing the same tab name.
const String _kDefaultInboxLabel = 'personal';

class _KeychainSheetState extends State<KeychainSheet>
    with TickerProviderStateMixin {
  List<Map<String, dynamic>> _keys = [];

  /// Each key's published inbox as `name/label`, keyed by key label, for the
  /// tile subtitle: picking a messaging key
  /// says which inbox people will reach. Absent = unknown (no XMTP client
  /// loaded to ask, or the key never made an inbox); '' = the key has an
  /// inbox that no directory lists.
  Map<String, String> _inboxAddressByKey = {};
  static final _kHex64 = RegExp(r'^[0-9a-f]{64}$');

  /// Each key's inbox (from its metadata stamp, else one XMTP lookup), then
  /// one directory read per owner: mine, plus the
  /// org of every org key, whose inbox lives in the ORG's directory and is
  /// named after the org (`publicos/admin`).
  Future<void> _loadInboxAddresses(
      String me, List<Map<String, dynamic>> keys) async {
    final inboxByKey = <String, String>{};
    final owners = <String>{me};
    for (final k in keys) {
      final label = k['label'] as String?;
      final address = k['address'] as String?;
      if (label == null || address == null) continue;
      // Stamped into key metadata at first activation, so no network and no
      // loaded client needed. Placeholders (`pending_initialization`,
      // `Error`) fail the hex check and fall back to asking XMTP, which does
      // need a loaded client.
      final stamped = (k['inboxId'] as String?)?.toLowerCase();
      final inboxId = (stamped != null && _kHex64.hasMatch(stamped))
          ? stamped
          : Contact.normalizeInboxId(
              await PublicOSConversations.inboxIdFromAddress(address));
      if (inboxId == null) continue;
      inboxByKey[label] = inboxId;
      final org = k['isGroupKey'] == true ? k['orgAddress'] as String? : null;
      if (org != null) owners.add(org);
    }
    if (inboxByKey.isEmpty) return;

    final named = <String, String>{};
    for (final owner in owners) {
      try {
        final ownerAddress = EthereumAddress.fromHex(owner);
        final dir = await PublicOSXmtp.getAllAccountInboxIds(ownerAddress);
        if (dir == null || dir.inboxIds.isEmpty) continue;
        final name = await PublicOSContacts
            .getPublicosDisplayNameByAccountAddress(ownerAddress);
        for (var i = 0; i < dir.inboxIds.length; i++) {
          final label = i < dir.labels.length ? dir.labels[i] : '';
          if (label.isEmpty) continue;
          named[bytes32ToString(dir.inboxIds[i])] =
              (name == null || name.isEmpty) ? label : '$name/$label';
        }
      } catch (_) {
        // RPC down: those keys stay "unregistered" until the next open.
      }
    }
    if (!mounted) return;
    setState(() => _inboxAddressByKey = {
          for (final e in inboxByKey.entries) e.key: named[e.value] ?? '',
        });
  }
  bool _isLoading = true;
  String? _error;
  String? _currentClientAddress;
  String? _currentInboxId;
  bool? _isCurrentInboxIdRegistered;
  String? _currentSelectedKey;
  String? _webSelectedKey; // Key selected for web/signing
  bool _hasKeyChanged = false;

  /// Connect grants held by this session -- the rows behind
  /// `ConnectGate.hasGrant`, read through Core's `listGrants` / `revokeSite`.
  /// Has a key fetch actually SUCCEEDED yet?
  ///
  /// The prune deletes grant rows permanently, and it decides what to delete by
  /// asking which keys exist -- so running it before the keychain has loaded
  /// means running it against an empty key set, which deletes every grant not
  /// made with the session key. Not hypothetical: guarding only on `_error`
  /// is not enough, because `initState` fires the key
  /// fetch and the web-key load in PARALLEL and unawaited -- one read versus N
  /// secure-storage reads plus key parsing -- so the fast path wins essentially
  /// every time and quietly wipes exactly the EOA-key grants.
  ///
  /// So this is an explicit "the inputs are known" flag, NOT `_keys.isNotEmpty`
  /// -- a user who has deleted all their EOA keys has an empty list AND real
  /// orphans to clean, and would never get pruned.
  bool _keysLoaded = false;

  List<ConnectedSite> _grants = const [];

  // NOTE: the first cut of this list was flat, and needed an "OTHER KEY" badge
  // to warn that a grant made with a different key exists but does not apply.
  // Filing each grant under the key that owns it says the same thing
  // structurally -- the "Current web key" toggle sits in the same panel -- so
  // the badge, and the resolved-EOA lookup that fed it, are gone.

  // Expand/collapse state — only one row expanded at a time (accordion).
  // Animation controllers are lazily created per key label so we only
  // animate rows the user has actually interacted with.
  String? _expandedLabel;
  final Map<String, AnimationController> _animControllers = {};
  final Map<String, Animation<double>> _expandAnims = {};

  @override
  void initState() {
    super.initState();
    _currentClientAddress = PublicOS.clientXmtpAddress;
    _fetchKeys();
    _checkCurrentInboxIdRegistration();
    _loadCurrentSelectedKey();
    _loadWebSelectedKey();

    // Re-entering the tour with a key ALREADY loaded: the offer fires on
    // generate and on a SIM tap, and neither is available to someone whose key
    // is already the current one — the SIM of the active key has no handler.
    // Declining the register dialog once therefore left an account with a
    // working inbox, no registration, and no control anywhere in this sheet
    // that would offer again.
    //
    // The offer gates itself on the inbox already existing and being
    // unpublished, so calling it on open is a no-op in every other case. Tour
    // only: outside the tour this sheet is not the place that nags.
    if (widget.onboardingMode == KeychainOnboardingMode.tour) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeOfferInboxRegistration();
      });
    }
  }

  @override
  void dispose() {
    for (final c in _animControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  AnimationController _getOrCreateController(String label) {
    if (!_animControllers.containsKey(label)) {
      final controller = AnimationController(
        duration: const Duration(milliseconds: 300),
        vsync: this,
      );
      _animControllers[label] = controller;
      _expandAnims[label] = CurvedAnimation(
        parent: controller,
        curve: Curves.easeInOut,
      );
    }
    return _animControllers[label]!;
  }

  Future<void> _toggleExpanded(String label) async {
    final controller = _getOrCreateController(label);
    if (_expandedLabel == label) {
      await controller.reverse();
      if (mounted) setState(() => _expandedLabel = null);
      return;
    }
    if (_expandedLabel != null) {
      await _animControllers[_expandedLabel]?.reverse();
    }
    if (!mounted) return;
    setState(() => _expandedLabel = label);
    unawaited(controller.forward());
  }

  Future<void> _loadWebSelectedKey() async {
    try {
      final currentUserAddress = AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
      if (currentUserAddress == null) return;

      final webKey = await PublicOSKeychain.getWebSelectedKey(currentUserAddress);

      if (mounted) {
        setState(() {
          _webSelectedKey = webKey;
        });
      }
    } catch (e) {
      print('Error loading web selected key: $e');
    }
  }

  /// Load this session's grants and **drop the orphans** -- rows whose granted
  /// key is no longer on the device.
  ///
  /// A grant is scoped to the session address (one account can hold several
  /// sessions on one device, and an account-scoped grant could not tell them
  /// apart), so every row here was necessarily created with a key that lived on
  /// THIS device. If its EOA is not in the keychain any more, the key was
  /// deleted and the row can never match again: `hasGrant` compares against the
  /// key about to be handed over, and that key no longer exists. Dead state
  /// that can only mislead.
  ///
  /// ⚠️ **The guard is the important part.** Grants never expire and there is
  /// no undo, so pruning against an EMPTY or FAILED key fetch would silently
  /// wipe every connection the user has. This runs only when the fetch actually
  /// produced the device's keys -- `_keys` populated and no error -- and it
  /// always counts the session key, which is not in `_keys` and is the one key
  /// that cannot be deleted.
  Future<void> _loadAndPruneGrants() async {
    final session = PublicOS.sessionBlockchainAddress?.toLowerCase();
    if (session == null) return;
    try {
      var rows = await PublicOS.database.listGrants(session);

      if (_keysLoaded) {
        final live = <String>{session};
        for (final k in _keys) {
          final a = (k['address'] as String?)?.toLowerCase();
          if (a != null && a.isNotEmpty && a != 'unknown') live.add(a);
        }
        final orphans =
            rows.where((r) => !live.contains(r.grantedEoa.toLowerCase()));
        for (final o in orphans) {
          debugPrint('[keychain] pruning orphan grant ${o.origin} '
              '(key ${o.grantedEoa} is no longer on this device)');
          await PublicOS.database.revokeSite(
            origin: o.origin,
            session: o.sessionAddress,
            eoa: o.grantedEoa,
          );
        }
        if (orphans.isNotEmpty) {
          rows = await PublicOS.database.listGrants(session);
        }
      }

      if (mounted) setState(() => _grants = rows);
    } catch (e) {
      // Non-fatal: the keychain's own job does not depend on this list.
      debugPrint('[keychain] could not load grants: $e');
    }
  }

  /// The grants belonging to one key, by its address. `null` asks for the
  /// session key's.
  List<ConnectedSite> _grantsForKey(String? address) {
    final a = (address ?? PublicOS.sessionBlockchainAddress ?? '').toLowerCase();
    if (a.isEmpty) return const [];
    return _grants.where((g) => g.grantedEoa.toLowerCase() == a).toList();
  }

  /// Drop one grant row. Exactly (origin, session, eoa) -- a site connected under
  /// two different keys keeps its other grant, which is the per-key model.
  Future<void> _revokeGrant(ConnectedSite g) async {
    try {
      await PublicOS.database.revokeSite(
        origin: g.origin,
        session: g.sessionAddress,
        eoa: g.grantedEoa,
      );
      await _loadAndPruneGrants();
    } catch (e) {
      _snackError(e);
    }
  }

  /// **Connected apps, for ONE key** -- the sites this key has been granted to.
  ///
  /// Per-key and not global, because that is what a grant actually is: the row
  /// is keyed by `(origin, session, EOA)` and `ConnectGate.hasGrant` asks about
  /// "the exact key about to be handed over". A flat list forced the reader to
  /// hold that mapping in their head; under the key it owns, the model is the
  /// layout.
  ///
  /// ⚠️ **A grant never expires.** `hasGrant` is `row != null`; `lastUsedAt` is
  /// a sort key, not a TTL, and nothing in the gate or the schema ages one out.
  /// The trash button here is the ONLY way a grant ever ends -- this is the
  /// app's sole revocation surface, not a read-only log.
  Widget _buildKeyGrants(String? address) {
    final tokens = GlassTokens.of(context);
    final grants = _grantsForKey(address);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        Row(
          children: [
            Icon(Icons.apps_rounded, size: 14, color: tokens.textDim),
            const SizedBox(width: 8),
            Text(
              'CONNECTED APPS',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.3,
                color: tokens.textDim,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${grants.length}',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: tokens.textDim.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (grants.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 22, bottom: 4),
            child: Text(
              'No apps connected with this key.',
              style: TextStyle(
                fontSize: 11,
                color: tokens.textDim.withValues(alpha: 0.7),
              ),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.only(left: 22, bottom: 8),
            child: Text(
              'Allowed to see this key\'s address. Access lasts until removed.',
              style: TextStyle(
                fontSize: 11,
                height: 1.3,
                color: tokens.textDim.withValues(alpha: 0.7),
              ),
            ),
          ),
          for (final g in grants) _buildGrantRow(tokens, g),
        ],
      ],
    );
  }

  /// Icon · title over url · trash.
  ///
  /// The title is DERIVED, because nothing stores one: a grant row carries only
  /// (origin, session, eoa, keyLabel, timestamps). [_siteTitle] guesses from the
  /// host, which is why the full origin sits directly underneath -- a wrong
  /// guess is harmless when the authoritative string is on screen.
  Widget _buildGrantRow(GlassTokens tokens, ConnectedSite g) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
      decoration: BoxDecoration(
        color: tokens.surfaceElevated.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          _SiteFavicon(origin: g.origin, tokens: tokens),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _siteTitle(g.origin),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: tokens.starkWhite,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  g.origin,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: tokens.textDim.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove access',
            icon: Icon(Icons.delete_outline_rounded,
                size: 17, color: tokens.textDim),
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            padding: EdgeInsets.zero,
            onPressed: () => _revokeGrant(g),
          ),
        ],
      ),
    );
  }

  /// A readable name for an origin, guessed from the host: drop a leading
  /// `www.` / `app.` / `m.` (they name a deployment, not a site) and title-case
  /// the first remaining label -- `https://app.zerion.io` -> `Zerion`,
  /// `https://quests.publicos.dev` -> `Quests`. Falls back to the raw origin for
  /// anything unparseable.
  String _siteTitle(String origin) {
    final host = Uri.tryParse(origin)?.host;
    if (host == null || host.isEmpty) return origin;
    var h = host;
    for (final prefix in const ['www.', 'app.', 'm.']) {
      if (h.startsWith(prefix)) {
        h = h.substring(prefix.length);
        break;
      }
    }
    final first = h.split('.').first;
    if (first.isEmpty) return host;
    return first[0].toUpperCase() + first.substring(1);
  }

  String _contextLabel(AppLocalizations l) =>
      widget.isGroupContext ? l.keychainGroupTitle : l.keychainTitle;
  String _contextSubtitle(AppLocalizations l) => widget.isGroupContext
      ? l.keychainGroupSubtitle(widget.groupName ?? '')
      : l.keychainSubtitle;

  Future<void> _loadCurrentSelectedKey() async {
    try {
      final currentUserAddress = AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
      if (currentUserAddress == null) return;

      final selectedKey = await PublicOSKeychain.getXmtpSelectedKey(currentUserAddress);

      if (mounted) {
        setState(() {
          _currentSelectedKey = selectedKey;
        });
      }
    } catch (e) {
      print('Error loading current selected key: $e');
    }
  }

  Future<void> _checkCurrentInboxIdRegistration() async {
    try {
      _currentInboxId = await PublicOS.xmtpClient?.getClientInboxId();
    } catch (e) {
      print("KeychainSheet: Error fetching current Inbox ID: $e");
      _currentInboxId = null;
    }

    if (_currentInboxId != null && _currentInboxId!.isNotEmpty) {
      try {
        final isRegistered = await PublicOSXmtp.accountInboxIdExists(StringToBytes(_currentInboxId!));
        if (mounted) {
          setState(() {
            _isCurrentInboxIdRegistered = isRegistered;
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _isCurrentInboxIdRegistered = false;
          });
          print("Error checking inbox ID registration: $e");
        }
      }
    } else {
      if (mounted) {
        setState(() {
          _isCurrentInboxIdRegistered = false;
        });
      }
    }
  }

  Future<void> _fetchKeys() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
      _keys = [];
    });

    try {
      final currentUserAddress = AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
      if (currentUserAddress == null) {
        _setErrorMsg((l) => l.errNoUserAddress);
        return;
      }

      final fetchedKeys = await PublicOSKeychain.fetchKeys(currentUserAddress);
      _setSuccessState(fetchedKeys);
      if (widget.type == KeychainType.xmtp) {
        unawaited(_loadInboxAddresses(currentUserAddress, fetchedKeys));
      }
    } catch (e) {
      _setError(e);
    }
  }

  void _setSuccessState(List<Map<String, dynamic>> keys) {
    if (!mounted) return;
    setState(() {
      _keys = keys;
      _keysLoaded = true;
      _isLoading = false;
      _error = null;
    });
    // ONLY here. The prune deletes rows and there is no undo, so it must run
    // downstream of the fetch that tells it which keys exist -- see
    // [_keysLoaded].
    unawaited(_loadAndPruneGrants());
  }

  void _setErrorState(String error) {
    if (!mounted) return;
    setState(() {
      _error = error;
      _isLoading = false;
    });
  }

  /// Localize a caught error for the inline error banner. Reading context.l10n
  /// in this sync method keeps async catch sites free of
  /// use_build_context_synchronously.
  void _setError(Object e, {String Function(AppLocalizations)? fallback}) {
    if (!mounted) return;
    final l10n = context.l10n;
    _setErrorState(localizedError(l10n, e, fallback: fallback?.call(l10n)));
  }

  /// Localize a caught error for a snackbar (same context-safety rationale).
  void _snackError(Object e, {String Function(AppLocalizations)? fallback}) {
    if (!mounted) return;
    final l10n = context.l10n;
    _showSnackBar(localizedError(l10n, e, fallback: fallback?.call(l10n)));
  }

  /// Localize a plain (non-error) message for a snackbar — reading context.l10n
  /// in this sync method keeps async call sites free of
  /// use_build_context_synchronously.
  void _snackMsg(String Function(AppLocalizations) pick) {
    if (!mounted) return;
    _showSnackBar(pick(context.l10n));
  }

  /// Same as [_snackMsg] but routes to the inline error banner.
  void _setErrorMsg(String Function(AppLocalizations) pick) {
    if (!mounted) return;
    _setErrorState(pick(context.l10n));
  }

  Future<void> _generateNewKey() async {
    final created = await _askNewKey();
    if (created == null) return;
    final label = created.label;

    try {
      setState(() => _isLoading = true);

      final currentUserAddress = AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
      if (currentUserAddress == null) {
        _setErrorMsg((l) => l.errNoUserAddress);
        return;
      }

      // Generate the key using PublicOSKeychain
      final keyData = await PublicOSKeychain.generateNewKey(
        currentUserAddress,
        label,
        isGroupKey: widget.isGroupContext,
        orgAddress: widget.orgAddress,
        emoji: created.emoji,
      );

      // Show mnemonic to user
      await _showMnemonicDialog(keyData['mnemonic'] as String, label);

      // A new key IS a key change, and this was the one place that never said
      // so — `onKeysChanged` fired on wallet-toggle, web-key-set and emoji
      // edits, but not on the most obvious change of all. Both listeners want
      // it: the wallet view reloads its list, and the tour's coach sequence
      // uses it to move the spotlight from GENERATE onto the SIM of the key
      // that just appeared.
      widget.onKeysChanged?.call();

      // Generating a key NEVER switches messaging on — in onboarding or out
      // of it: the user may not want to load it into XMTP. Making a key and
      // pointing XMTP at one are two separate
      // operations, and collapsing them hides the SIM icon, which is the only
      // way to change keys later. The publish-inbox offer goes with the
      // activation: it fires from the SIM tap (_selectKey).
      _fetchKeys();
      _snackMsg((l) => l.keychainKeyCreated);
    } catch (e) {
      _setError(e);
    }
  }

  /// The create-a-key dialog: avatar (random to start, tap to pick), label,
  /// and one line saying what generating does NOT do. Null on cancel.
  /// Desktop twin: `keychain_dialog._askNewKey`.
  /// [forImport]: the same prompt for an IMPORTED key (name and icon are
  /// picked when importing too) — import title + hint, IMPORT as
  /// the action, and no "generating does not…" line.
  Future<_NewKey?> _askNewKey({bool forImport = false}) {
    final controller = TextEditingController();
    var emoji = randomKeyEmoji();

    return showDialog<_NewKey>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final tokens = GlassTokens.of(ctx);
          void submit() {
            final label = controller.text.trim();
            if (label.isNotEmpty) {
              Navigator.pop(ctx, _NewKey(label: label, emoji: emoji));
            }
          }

          return AlertDialog(
            constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.m),
            title: Row(
              children: [
                Icon(Icons.key_rounded, size: 20, color: tokens.starkWhite),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(forImport
                      ? ctx.l10n.keychainEnterLabelTitle
                      : widget.isGroupContext
                          ? ctx.l10n.keychainGenGroupTitle
                          : ctx.l10n.keychainGenTitle),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // The avatar the key will wear in the list; the same
                    // picker the tile's emoji opens later.
                    Tooltip(
                      message: ctx.l10n.keychainGenEmojiHint,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () async {
                          final picked = await showEmojiPickerDialog(ctx,
                              currentEmoji: emoji);
                          if (picked != null && picked.isNotEmpty) {
                            setLocal(() => emoji = picked);
                          }
                        },
                        child: Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: tokens.surfaceElevated,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Text(emoji,
                                style: const TextStyle(fontSize: 26)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: controller,
                        autofocus: true,
                        maxLength: 50,
                        decoration: InputDecoration(
                          labelText: ctx.l10n.keychainKeyLabel,
                          hintText: forImport
                              ? ctx.l10n.keychainImportLabelHint
                              : ctx.l10n.keychainKeyLabelHint,
                        ),
                        onSubmitted: (_) => submit(),
                      ),
                    ),
                  ],
                ),
                if (!forImport) ...[
                const SizedBox(height: 4),
                Text(
                  ctx.l10n.keychainGenExplain,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: tokens.textDim,
                  ),
                ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(ctx.l10n.dlgCancel),
              ),
              TextButton(
                onPressed: submit,
                child: Text(forImport
                    ? ctx.l10n.keychainImport
                    : ctx.l10n.keychainGenerate),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showMnemonicDialog(String mnemonic, String label) async {
    await showSecretRevealDialog(
      context,
      title: context.l10n.keychainRecoveryTitle,
      subtitle: label,
      warning: context.l10n.keychainRecoveryWarning,
      secret: mnemonic,
    );
  }

  /// Desktop twin: `keychain_dialog._confirm`. Same glass-dark shell as the
  /// inbox-tab dialogs, so every keychain confirm looks like one family.
  Future<bool?> _confirm({
    required String title,
    required String body,
    required String cta,
    bool destructive = false,
    String? cancel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) {
        final tokens = GlassTokens.of(ctx);
        // Severity rule: destructive = red icon +
        // red uppercase title, body in textDim.
        final accent = destructive
            ? Theme.of(ctx).colorScheme.error
            : tokens.starkWhite;
        return Dialog(
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: GlassTheme.glassBox(ctx).copyWith(
                color: tokens.surfaceDeep,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        destructive
                            ? Icons.warning_amber_rounded
                            : Icons.help_outline_rounded,
                        size: 20,
                        color: accent,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          title.toUpperCase(),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'SpaceGrotesk',
                            color: accent,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    body,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'SpaceGrotesk',
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
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text(
                            cancel ?? ctx.l10n.dlgCancel,
                            style: const TextStyle(
                              fontFamily: 'SpaceGrotesk',
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
                            backgroundColor: accent,
                            foregroundColor: tokens.background,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text(
                            cta,
                            style: const TextStyle(
                              fontFamily: 'SpaceGrotesk',
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
          ),
        );
      },
    );
  }

  Future<void> _deleteKey(String label) async {
    // The key messaging runs on gets two warnings, then is unloaded before it
    // is deleted. Any other key: the single confirm.
    final bool loaded = PublicOS.currentXmtpKeyLabel == label;
    if (loaded) {
      final first = await _confirm(
        title: context.l10n.keychainDeleteLoadedTitle,
        body: context.l10n.keychainDeleteLoadedBody(label),
        cta: context.l10n.keychainDeleteContinue,
      );
      if (first != true || !mounted) return;
      final second = await _confirm(
        title: context.l10n.keychainDeleteLoadedPhraseTitle,
        body: context.l10n.keychainDeleteLoadedPhraseBody,
        cta: context.l10n.keychainDelete,
        destructive: true,
      );
      if (second != true) return;
    } else {
      final bool? confirmed = await _confirm(
        title: context.l10n.keychainDeleteTitle,
        body: context.l10n.keychainDeleteConfirm(label),
        cta: context.l10n.keychainDelete,
        destructive: true,
      );
      if (confirmed != true) return;
    }

    // Second question: the key's chats stay on the device unless the user says
    // so here. Asked only when this key has chat data on this device.
    // Dismissing the dialog stops the whole delete.
    final currentAddr = AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
    bool deleteChats = false;
    String? chatsInbox;
    if (currentAddr != null) {
      chatsInbox = await PublicOSKeychain.keyChatsInboxId(currentAddr, label);
      if (!mounted) return;
      if (chatsInbox != null) {
        final short = chatsInbox.length > 12
            ? '${chatsInbox.substring(0, 6)}...${chatsInbox.substring(chatsInbox.length - 4)}'
            : chatsInbox;
        final answer = await _confirm(
          title: context.l10n.keychainDeleteChatsTitle,
          body: context.l10n.keychainDeleteChatsBody(short),
          cta: context.l10n.keychainDeleteChatsDelete,
          cancel: context.l10n.keychainDeleteChatsKeep,
          destructive: true,
        );
        if (answer == null || !mounted) return;
        deleteChats = answer;
      }
    }
    // The same inbox may be loaded under another label of this key.
    final unloadForChats = deleteChats &&
        !loaded &&
        chatsInbox != null &&
        PublicOS.clientXmtpInboxId == chatsInbox;

    try {
      setState(() => _isLoading = true);

      final currentUserAddress = AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
      if (currentUserAddress == null) {
        _setErrorMsg((l) => l.errNoUserAddress);
        return;
      }

      // Unload first, then delete — never the other way round.
      if (loaded || unloadForChats) {
        await _unloadXmtp();
        _currentClientAddress = null;
        _currentInboxId = null;
      }

      await PublicOSKeychain.deleteKey(currentUserAddress, label,
          deleteChats: deleteChats);

      // Update selection state if deleted key was selected
      if (_currentSelectedKey == label) {
        _currentSelectedKey = null;
      }

      _snackMsg((l) => loaded ? l.keychainKeyDeletedUnloaded : l.keychainKeyDeleted);
      widget.onKeysChanged?.call();
      _fetchKeys();
    } catch (e) {
      _setError(e);
    }
  }

  /// Unload the XMTP client WITHOUT loading another key (a loaded key is
  /// unloaded first, then deleted). Core's deleteKey only clears the loaded-key
  /// fields, and only when the key is also the saved selection; it never stops
  /// the stream, closes the native client or flips the connected flag, so
  /// without this the UI would report a client for a key that no longer
  /// exists. Same calls
  /// Core uses before a re-init: stream off, native client closed, status
  /// false, loaded-key fields cleared. Messaging stays off until a key is picked.
  static Future<void> _unloadXmtp() async {
    try {
      await PublicOSConversations.disposeMessages();
    } catch (_) {}
    try {
      await PublicOS.xmtpClient?.closeClient();
    } catch (_) {}
    PublicOS.setXmtpConnected(false);
    PublicOS.currentXMTPPrivateKey = null;
    PublicOS.clientXmtpAddress = null;
    PublicOS.clientXmtpInboxId = null;
    PublicOS.currentXmtpDbKey = null;
    PublicOS.currentXmtpKeyLabel = null;
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    _showSnackBar(context.l10n.keychainAddressCopied);
  }

  /// "Add to another inbox": the key as a QR for the user's other phone
  /// (the QR key handoff). The bytes are zeroed once the dialog closes.
  Future<void> _showKeyQr(String label) async {
    final me = AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
    if (me == null) {
      _snackMsg((l) => l.errNoUserAddress);
      return;
    }
    try {
      final hex = await PublicOSKeychain.exportPrivateKey(me, label);
      if (hex == null) {
        _snackMsg((l) => l.keychainPrivKeyNotFound);
        return;
      }
      if (!mounted) return;
      final bytes = PublicOSKeychain.hexToBytes(hex);
      try {
        await showKeyQrDialog(context, privateKey: bytes, keyLabel: label);
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
    } catch (e) {
      _snackError(e);
    }
  }

  bool _refreshingKeys = false;

  Future<void> _refreshKeys() async {
    if (_refreshingKeys) return;
    final me = AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
    if (me == null) {
      _snackMsg((l) => l.errNoUserAddress);
      return;
    }
    setState(() => _refreshingKeys = true);
    try {
      final moved = await PublicOSKeychain.refreshInboxStamps(me);
      final active = PublicOS.currentXmtpKeyLabel;
      if (active != null && moved.contains(active) && mounted) {
        // The running client still talks to the key's OLD inbox: reload it
        // through the activation gate (it asks before setting up the new
        // inbox on this device).
        await activateKeyForXmtp(context, me, active);
      }
      await _fetchKeys();
      await _loadCurrentSelectedKey();
      _currentClientAddress = PublicOS.clientXmtpAddress;
      await _checkCurrentInboxIdRegistration();
      if (!mounted) return;
      _showSnackBar(moved.isEmpty
          ? context.l10n.keychainRefreshDone
          : context.l10n.keychainRefreshMoved(moved.join(', ')));
    } catch (e) {
      _snackError(e);
    } finally {
      if (mounted) setState(() => _refreshingKeys = false);
    }
  }

  Future<void> _exportPrivateKeyAsInt(String label) async {
    try {
      final currentUserAddress = AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
      if (currentUserAddress == null) {
        _snackMsg((l) => l.errNoUserAddress);
        return;
      }

      final privateKeyHex = await PublicOSKeychain.exportPrivateKey(currentUserAddress, label);

      if (privateKeyHex == null) {
        _snackMsg((l) => l.keychainPrivKeyNotFound);
        return;
      }

      // Keys derived from a mnemonic can reveal both formats; a private-key
      // import only has the hex. The export dialog hides the toggle when the
      // mnemonic is null.
      final mnemonic =
          await PublicOSKeychain.exportMnemonic(currentUserAddress, label);

      if (!mounted) return;
      await showExportKeyDialog(
        context,
        mnemonic: mnemonic,
        privateKey: privateKeyHex,
        keyLabel: label,
      );
    } catch (e) {
      _snackError(e);
    }
  }

  Future<void> _showImportSheet() async {
    final isGroup = widget.isGroupContext;
    final groupAddr = widget.orgAddress;
    final onChanged = widget.onKeysChanged;
    bool didImport = false;

    // Keep the keychain open and stack the import sheet on top. On close we
    // reload the key list in place so the freshly imported key appears,
    // mirroring how Generate stays on the keychain instead of dismissing it.
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ImportKeySheet(
        title: isGroup
            ? ctx.l10n.keychainImportGroupTitle
            : ctx.l10n.keychainImportTitle,
        subtitle: ctx.l10n.keychainImportSubtitle,
        onImportMnemonic: (mnemonic) async {
          final address = AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
          if (address == null) return false;
          // Label AND icon, the generate prompt reused.
          final named = await _askNewKey(forImport: true);
          if (named == null) return false;
          // Passive import — stores the key only; no XMTP client is touched
          // and no installation is registered. The user sets up messaging
          // later by activating the key (chip tap / Messages view).
          await PublicOSKeychain.importFromMnemonic(
            address, mnemonic, named.label,
            isGroupKey: isGroup, orgAddress: groupAddr, emoji: named.emoji,
          );
          didImport = true;
          onChanged?.call();
          return true;
        },
        onImportPrivateKey: (privateKey) async {
          final address = AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
          if (address == null) return false;
          final named = await _askNewKey(forImport: true);
          if (named == null) return false;
          // Passive import — see onImportMnemonic.
          await PublicOSKeychain.importFromPrivateKey(
            address, privateKey, named.label,
            isGroupKey: isGroup, orgAddress: groupAddr, emoji: named.emoji,
          );
          didImport = true;
          onChanged?.call();
          return true;
        },
      ),
    );

    // Reload the keychain list in place once the import sheet closes.
    if (didImport && mounted) {
      _fetchKeys();
    }
  }

  /// Installation-cap recovery: informed-choice dialog → two-step
  /// confirm → revoke ALL of the key's installations signed by the imported
  /// key itself. Returns true when the revoke succeeded and the import should
  /// be retried; false on cancel or failure (failure is shown in a dialog —
  /// never silently, and never the cache-wipe dialog).
  static Future<bool> _runInstallCapRecovery(
    BuildContext context,
    String walletAddress,
    Future<Uint8List> Function() getKeyBytes,
  ) async {
    final choseRevokeAll = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.m),
        title: Text(ctx.l10n.keychainInstallCapTitle),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(ctx.l10n
                  .keychainInstallCapBody(walletAddress.substring(0, 10))),
              const SizedBox(height: 16),
              Text(ctx.l10n.keychainInstallCapRevokeAll,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(ctx.l10n.keychainInstallCapRevokeAllDetail),
              const SizedBox(height: 12),
              Text(ctx.l10n.keychainInstallCapSelective,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(ctx.l10n.keychainInstallCapSelectiveDetail),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.dlgCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l10n.keychainInstallCapRevokeAll),
          ),
        ],
      ),
    );
    if (choseRevokeAll != true || !context.mounted) return false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
        title: Text(ctx.l10n.keychainInstallCapConfirmTitle),
        content: Text(ctx.l10n.keychainInstallCapConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.dlgCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l10n.keychainInstallCapRevokeAll),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return false;

    try {
      final keyBytes = await getKeyBytes();
      await PublicOSKeychain.revokeAllInstallationsForCap(
          keyBytes, walletAddress);
      return true;
    } catch (e) {
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
            title: Text(ctx.l10n.keychainInstallCapTitle),
            content:
                Text(ctx.l10n.keychainInstallCapRevokeFailed(e.toString())),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(ctx.l10n.dlgOk),
              ),
            ],
          ),
        );
      }
      return false;
    }
  }

  /// The loaded key's green sim, pressed. Same unload the delete path runs,
  /// with no delete: stream off, native client closed, loaded-key fields
  /// cleared. The saved selection is cleared too, so the next start does not
  /// load it back. Pops `true` like a load, so every host that reloads on a key
  /// change reloads on this.
  Future<void> _unloadKey() async {
    try {
      setState(() => _isLoading = true);
      await _unloadXmtp();
      final addr =
          AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
      if (addr != null) await PublicOSKeychain.clearXmtpSelectedKey(addr);
      _currentClientAddress = null;
      _currentInboxId = null;
      _currentSelectedKey = null;
      _snackMsg((l) => l.keychainKeyUnloaded);
      widget.onKeysChanged?.call();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        _snackError(e);
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _selectKey(String label, String privateKeyHex) async {
    try {
      setState(() => _isLoading = true);

      final currentUserAddress = AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
      if (currentUserAddress == null) {
        _snackMsg((l) => l.errNoUserAddress);
        return;
      }

      // Load the key. If it isn't set up for messaging on this device, the
      // orchestrator asks the user to create fresh or restore a backup —
      // activation never assumes.
      final loaded =
          await activateKeyForXmtp(context, currentUserAddress, label);
      if (!loaded) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      _snackMsg((l) => l.keychainClientReloaded(label));

      // Update current client info and selection state
      _currentClientAddress = PublicOS.clientXmtpAddress;
      _currentInboxId = PublicOS.clientXmtpInboxId;
      _currentSelectedKey = label;

      await _checkCurrentInboxIdRegistration();

      // Offer BEFORE the pop — once this sheet closes there is no context to
      // show the dialog in, and the moment has passed.
      if (mounted) setState(() => _isLoading = false);
      await _maybeOfferInboxRegistration();

      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        _snackError(e);
        setState(() => _isLoading = false);
      }
    }
  }

  /// Orchestrates loading a key into XMTP (the single gate every activation
  /// entry point funnels through — chip tap, onboarding, Messages view).
  ///
  /// If the key is already set up on this device it loads silently. If not,
  /// the gate first asks the NETWORK whether this key has an inbox at all
  /// (`PublicOSKeychain.isKeyOnXmtpNetwork`, no client needed, nothing
  /// registered):
  ///
  ///  * **no inbox** -> there is nothing to restore, so it sets up fresh
  ///    without asking. This is the just-generated key, and the old question
  ///    ("create fresh or restore a backup?") was unanswerable for it.
  ///  * **has an inbox**, or the probe could not tell (offline / web) -> ask,
  ///    exactly as before. Never assume "no inbox" from a failed lookup: that
  ///    would spend an installation and strand the user's history.
  ///
  /// [freshKey] still short-circuits straight to "create" for a caller that
  /// already knows the key is brand new. Returns true when the client ends up
  /// loaded.
  static Future<bool> activateKeyForXmtp(
    BuildContext context,
    String userAddress,
    String label, {
    bool freshKey = false,
  }) async {
    debugPrint('KeychainSheet: [ACTIVATE] label="$label" freshKey=$freshKey');
    try {
      await PublicOSKeychain.selectKey(userAddress, label);
      debugPrint('KeychainSheet: [ACTIVATE] key was already set up — loaded directly');
      return true;
    } on XmtpNotSetUpException catch (e) {
      debugPrint('KeychainSheet: [ACTIVATE] not set up here (status=${e.status.name}) — asking');
      if (freshKey) {
        return _setupFreshWithCapRecovery(context, userAddress, label);
      }
      // Does this key have an inbox on the network at all? Only then is
      // "restore a backup" a real option.
      final onNetwork =
          await PublicOSKeychain.isKeyOnXmtpNetwork(userAddress, label);
      debugPrint(
          'KeychainSheet: [ACTIVATE] on network = ${onNetwork ?? "unknown"}');
      if (onNetwork == false) {
        if (!context.mounted) return false;
        return _setupFreshWithCapRecovery(context, userAddress, label);
      }
      // Does the account's SSP hold a chat backup made with this key (the
      // "Backup to SSP" row on the other device, kept 24 hours)? Then the
      // dialog offers it. Any failure reads as "none": the other two options
      // are still there.
      PediaFile? sspBackup;
      try {
        sspBackup = await PublicOSKeychain.findChatBackup(userAddress, label)
            .timeout(const Duration(seconds: 8));
      } catch (e) {
        debugPrint('KeychainSheet: [ACTIVATE] SSP backup lookup failed: $e');
      }
      debugPrint(
          'KeychainSheet: [ACTIVATE] SSP backup = ${sspBackup?.id ?? "none"}');
      if (!context.mounted) return false;
      final choice =
          await _showSetupChoiceDialog(context, sspBackup: sspBackup);
      debugPrint('KeychainSheet: [ACTIVATE] user chose: ${choice?.name ?? "cancel"}');
      switch (choice) {
        case _XmtpSetupChoice.createFresh:
          return _setupFreshWithCapRecovery(context, userAddress, label);
        case _XmtpSetupChoice.restore:
          return _runRestoreBackup(context, userAddress, label);
        case _XmtpSetupChoice.restoreSsp:
          return _runRestoreFromSsp(context, userAddress, label, sspBackup!);
        case null:
          return false;
      }
    }
  }

  /// Set up a fresh installation, recovering from the 10/10 cap if hit.
  static Future<bool> _setupFreshWithCapRecovery(
      BuildContext context, String userAddress, String label) async {
    try {
      debugPrint('KeychainSheet: [SETUP-FRESH] calling setupFreshXmtp…');
      await PublicOSKeychain.setupFreshXmtp(userAddress, label);
      debugPrint('KeychainSheet: [SETUP-FRESH] SUCCESS');
      return true;
    } on XmtpInstallationCapException catch (e) {
      debugPrint('KeychainSheet: [SETUP-FRESH] installation cap hit for ${e.walletAddress}');
      if (!context.mounted) return false;
      final proceed = await _runInstallCapRecovery(context, e.walletAddress,
          () async {
        final hex = await PublicOSKeychain.exportPrivateKey(userAddress, label);
        if (hex == null) throw Exception('Private key not found');
        return EthPrivateKey.fromHex(hex).privateKey;
      });
      if (!proceed) return false;
      await PublicOSKeychain.setupFreshXmtp(userAddress, label);
      return true;
    } catch (e, st) {
      debugPrint('KeychainSheet: [SETUP-FRESH] FAILED: $e\n$st');
      if (context.mounted) {
        await _showSimpleDialog(
            context, context.l10n.keychainSetupTitle, e.toString());
      }
      return false;
    }
  }

  /// Restore a raw database backup (file + encryption key) for a key that is
  /// not set up on this device — the SAME installation, no slot burned.
  static Future<bool> _runRestoreBackup(
      BuildContext context, String userAddress, String label) async {
    final l10n = context.l10n;
    // 1. Pick the backup file. NO extension filter — `file_selector_android`
    // rejects arbitrary extensions like `.db3` ("Extension not supported"),
    // and backups can be typed as anything by the OS document provider, so we
    // accept any file and validate on open. Path-based (XFile.path) avoids the
    // Windows file_picker null-bytes gotcha.
    final XFile? picked;
    try {
      picked = await openFile();
    } catch (e, st) {
      debugPrint('KeychainSheet: [RESTORE] file pick failed: $e\n$st');
      if (context.mounted) {
        await _showSimpleDialog(
            context, l10n.keychainRestoreTitle, e.toString());
      }
      return false;
    }
    if (picked == null) {
      debugPrint('KeychainSheet: [RESTORE] no file picked (cancelled)');
      return false;
    }
    debugPrint('KeychainSheet: [RESTORE] picked name=${picked.name} path=${picked.path}');
    if (!context.mounted) return false;

    // 2. Paste the database encryption key.
    final key = await _promptSecretText(
      context,
      title: l10n.keychainRestoreTitle,
      message: l10n.keychainRestoreKeyPrompt,
      hint: l10n.keychainRestoreKeyHint,
    );
    if (key == null || key.trim().isEmpty || !context.mounted) {
      debugPrint('KeychainSheet: [RESTORE] no encryption key entered');
      return false;
    }
    debugPrint('KeychainSheet: [RESTORE] key entered (len=${key.trim().length}), calling restoreXmtpBackup…');

    // 3. Restore.
    try {
      await PublicOSKeychain.restoreXmtpBackup(
          userAddress, label, picked.path, key.trim());
      debugPrint('KeychainSheet: [RESTORE] SUCCESS');
      return true;
    } catch (e, st) {
      debugPrint('KeychainSheet: [RESTORE] FAILED: $e\n$st');
      if (context.mounted) {
        // Show the RAW error text while we\'re debugging this flow.
        await _showSimpleDialog(
            context, l10n.keychainRestoreFailedTitle, e.toString());
      }
      return false;
    }
  }

  /// Restore the chat backup the account's SSP holds for this key: the SAME
  /// installation as the device that made it, no slot burned, nothing to
  /// pick or paste. The server copy is left for its 24 hour timer.
  static Future<bool> _runRestoreFromSsp(BuildContext context,
      String userAddress, String label, PediaFile backup) async {
    final l10n = context.l10n;
    final overlay =
        FullscreenOverlay.showBlocking(context, l10n.keychainRestoreSspWorking);
    try {
      final tmpDir = await getTemporaryDirectory();
      await PublicOSKeychain.restoreChatBackup(
          userAddress, label, backup, tmpDir.path);
      debugPrint('KeychainSheet: [RESTORE-SSP] SUCCESS');
      overlay.dismiss();
      return true;
    } catch (e, st) {
      debugPrint('KeychainSheet: [RESTORE-SSP] FAILED: $e\n$st');
      overlay.dismiss();
      if (context.mounted) {
        await _showSimpleDialog(
            context,
            l10n.keychainRestoreFailedTitle,
            e is ChatBackupKeyException
                ? l10n.keychainRestoreSspWrongKey
                : e.toString());
      }
      return false;
    }
  }

  /// When a chat backup was made, in the user's own time and language.
  static String _backupWhen(BuildContext context, PediaFile backup) {
    final made = DateTime.tryParse(backup.createdAt)?.toLocal();
    if (made == null) return backup.createdAt;
    final locale = Localizations.localeOf(context).toLanguageTag();
    return DateFormat.MMMd(locale).add_Hm().format(made);
  }

  /// The create-vs-restore choice shown when a key is not set up here.
  /// [sspBackup] adds the third option, restore from the user's SSP.
  static Future<_XmtpSetupChoice?> _showSetupChoiceDialog(BuildContext context,
      {PediaFile? sspBackup}) {
    return showDialog<_XmtpSetupChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.m),
        title: Text(ctx.l10n.keychainSetupTitle),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(ctx.l10n.keychainSetupBody),
              const SizedBox(height: 16),
              Text(ctx.l10n.keychainSetupCreateFresh,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(ctx.l10n.keychainSetupCreateFreshDetail),
              const SizedBox(height: 12),
              Text(ctx.l10n.keychainSetupRestore,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(ctx.l10n.keychainSetupRestoreDetail),
              if (sspBackup != null) ...[
                const SizedBox(height: 12),
                Text(ctx.l10n.keychainSetupRestoreSsp,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(ctx.l10n.keychainSetupRestoreSspDetail(
                    _backupWhen(ctx, sspBackup))),
              ],
              const SizedBox(height: 16),
              // Guidance, not a third option. A key with no
              // inbox on the network never reaches this dialog at all (the
              // gate sets it up fresh silently), so the brand-new-key case is
              // normally absent — but it still lands here when the probe cannot
              // reach the network. This line tells the user which side of the
              // choice they are on instead of leaving them to guess.
              Text(
                ctx.l10n.keychainSetupHint,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  fontStyle: FontStyle.italic,
                  color: Theme.of(ctx)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.65),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.l10n.dlgCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _XmtpSetupChoice.restore),
            child: Text(ctx.l10n.keychainSetupRestore),
          ),
          if (sspBackup != null)
            TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, _XmtpSetupChoice.restoreSsp),
              child: Text(ctx.l10n.keychainSetupRestoreSsp),
            ),
          // **Start fresh is the recommended action, and it is emphasised.**
          // Three identical TextButtons made this read as a genuine three-way
          // choice, but it is not one: restoring needs a database file exported
          // from another device, so it only applies to a key that has already
          // lived somewhere else. Every key generated moments earlier in
          // onboarding lands here with nothing to restore — the body copy
          // already says so — and the buttons should agree with the copy
          // instead of leaving the user to weigh two equal-looking options.
          // FilledButton is the app's affirmative tier (see chat_screen's
          // consent row).
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _XmtpSetupChoice.createFresh),
            child: Text(ctx.l10n.keychainSetupCreateFresh),
          ),
        ],
      ),
    );
  }

  static Future<String?> _promptSecretText(BuildContext context,
      {required String title, required String message, required String hint}) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.m),
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(hintText: hint),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.l10n.dlgCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(ctx.l10n.keychainImport),
          ),
        ],
      ),
    );
  }

  static Future<void> _showSimpleDialog(
      BuildContext context, String title, String body) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.l10n.dlgOk),
          ),
        ],
      ),
    );
  }

  Future<void> _registerCurrentInboxId(String inboxIdString) async {
    if (_isCurrentInboxIdRegistered == true) {
      _snackMsg((l) => l.keychainInboxAlreadyReg);
      return;
    }

    final TextEditingController labelController = TextEditingController();
    final String? label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.m),
        title: Text(context.l10n.keychainRegInboxTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.l10n
                .keychainRegInboxPrompt(shortenString(inboxIdString))),
            const SizedBox(height: 10),
            TextField(
              controller: labelController,
              decoration:
                  InputDecoration(labelText: context.l10n.keychainLabelField),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.dlgCancel),
          ),
          TextButton(
            onPressed: () {
              // The chain takes `[a-z0-9._-]` only (inboxLabelFrom).
              final label = inboxLabelFrom(labelController.text.trim());
              if (label.isNotEmpty) {
                Navigator.pop(context, label);
              } else {
                _showSnackBar(context.l10n.keychainEnterLabelPlease);
              }
            },
            child: Text(context.l10n.keychainRegister),
          ),
        ],
      ),
    );

    if (label == null || label.isEmpty) return;

    try {
      setState(() => _isLoading = true);

      final existingAccountAddress = await PublicOSXmtp.getAccountAddressByInboxId(StringToBytes(inboxIdString));
      if (existingAccountAddress != null) {
        _snackMsg((l) => l.keychainInboxRegOther);
        return;
      }

      final success = widget.isGroupContext
          ? await PublicOSGovernance.registerInboxIdForOrg(
              widget.orgAddress!,
              StringToBytes(inboxIdString),
              label,
            )
          : await PublicOSXmtp.registerInboxId(StringToBytes(inboxIdString), label);

      if (success) {
        _snackMsg((l) => l.keychainInboxRegOk);
        await _checkCurrentInboxIdRegistration();
      } else {
        _snackMsg((l) => l.keychainInboxRegFail);
      }
    } catch (e) {
      _snackError(e);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  Publish-this-inbox offer
  //
  //  Fires ONCE the XMTP client is loaded with a key — never at create or
  //  import time. That timing is the whole design: activation is the first
  //  moment an inbox ID exists at all (import is passive by design and touches
  //  no XMTP client), so there is no "does this key have an inbox?" question
  //  to answer and no network lookup to invent. If the client loaded, there is
  //  an inbox.
  //
  //  Three gates, cheapest first — the local setting, then the two chain reads:
  //    1. has the user switched the offer off?     → local setting
  //    2. is this inbox already published?         → accountInboxIdExists
  //    3. can this account write to chain at all?  → isDomainCompliant
  //
  //  (3) is not politeness: registering is an on-chain write and the consensus
  //  gate is domain compliance, so offering it to a non-compliant account
  //  promises something that would revert.
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> _maybeOfferInboxRegistration() async {
    // During the tour this dialog is not an offer, it is **step 3.4** — the one
    // on-chain write the whole sequence exists to reach. So the user's standing
    // "don't ask again" is not consulted and the checkbox is not shown: someone
    // who dismissed the offer once, months ago, would otherwise walk a coach
    // sequence whose final beat silently never happens, with no way to tell
    // that anything was skipped.
    final inTour = widget.onboardingMode == KeychainOnboardingMode.tour;

    // Gate 1 — the user's own "don't ask again".
    if (!inTour) {
      try {
        final off =
            await PublicOSSettings.getSetting(KeychainSheet.kInboxPromptOffKey);
        if (off?.value == 'true') return;
      } catch (_) {
        // Setting unreadable — fall through and ask. Missing the prompt is
        // worse than one extra dialog.
      }
    }

    final inboxId = PublicOS.clientXmtpInboxId;
    if (inboxId == null || inboxId.isEmpty) return;

    // Gate 1b: the user already answered "Keep private" for this key.
    final keepPrivateKey = KeychainSheet.kInboxKeepPrivatePrefix + inboxId;
    if (!inTour) {
      try {
        final kept = await PublicOSSettings.getSetting(keepPrivateKey);
        if (kept?.value == 'true') return;
      } catch (_) {
        // Unreadable: ask.
      }
    }

    // Gate 2 — already published for this account.
    try {
      if (await PublicOSXmtp.accountInboxIdExists(StringToBytes(inboxId))) {
        return;
      }
    } catch (_) {
      return; // Cannot tell — say nothing rather than offer a duplicate.
    }

    // Gate 3 — domain compliance, the consensus gate for any write. Note this
    // one THROWS on a failed read (unlike the check above, which returns
    // false), so the catch is load-bearing: an unverifiable domain means we
    // stay quiet. The manual row in this same sheet is always still there.
    final myAddress = AppStateNotifier.currentMyContact?.publicosAddress;
    if (myAddress == null) return;
    try {
      if (!await PublicOSTreasury.isDomainCompliant(myAddress)) return;
    } catch (_) {
      return;
    }

    // Asked before the dialog is built so the field can open already filled.
    // One extra view call on a path that has just done three.
    final defaultLabel = await _defaultInboxLabel(myAddress);

    if (!mounted) return;
    // THE shared inbox-tab dialog — the same surface the Inbox
    // IDs page opens for register/rename. It runs the ownership pre-check and
    // the write itself, and only pops `saved` once the chain confirmed.
    final result = await showInboxTabDialog(
      context,
      account: myAddress,
      accountName: AppStateNotifier.currentMyContact?.publicosDisplayName,
      inboxIdBytes: StringToBytes(inboxId),
      mode: InboxTabMode.register,
      title: context.l10n.keychainOfferRegTitle,
      subtitle: context.l10n.keychainOfferRegBody(shortenString(inboxId)),
      cta: context.l10n.keychainOfferRegPublish,
      initialLabel: defaultLabel,
      offerDontAsk: !inTour,
      cancelLabel: context.l10n.keychainOfferRegKeepPrivate,
    );
    if (result == null) return;

    // "Keep private" pressed: remember the no for this key.
    if (!result.saved && !inTour) {
      try {
        await PublicOSSettings.setSetting(
          keepPrivateKey,
          Record.asSettings(
            key: keepPrivateKey,
            value: 'true',
            isSystem: true,
            isExpired: false,
          ),
        );
      } catch (_) {
        // Non-fatal: worst case we ask again next time.
      }
    }

    if (result.dontAskAgain) {
      try {
        await PublicOSSettings.setSetting(
          KeychainSheet.kInboxPromptOffKey,
          Record.asSettings(
            key: KeychainSheet.kInboxPromptOffKey,
            value: 'true',
            isSystem: true,
            isExpired: false,
          ),
        );
      } catch (_) {
        // Non-fatal: worst case we ask again next time.
      }
    }

    // Failures do not reach here: the dialog stays open and explains them
    // in place. A pop with `saved` false means the user left.
    if (!result.saved) return;
    _snackMsg((l) => l.keychainInboxRegOk);
    await _checkCurrentInboxIdRegistration();
  }

  /// The default tab name to offer, or `null` for an empty field.
  ///
  /// `personal` is the name the whole system already uses for a first inbox,
  /// including when a profile is published unattended. So it is pre-filled when it is free, and
  /// the field is left **empty with its hint** when it is not: a second key on
  /// an account that already has `personal` would otherwise arrive at a
  /// prefilled name that is guaranteed to revert on
  /// `labelExists(account, label)`.
  ///
  /// Read through `getAllAccountInboxIds`, which returns **null on failure** —
  /// so an unreadable account is treated the same as a taken name and gets an
  /// empty field. Guessing a default we cannot verify is the one outcome that
  /// spends gas to find out.
  static Future<String?> _defaultInboxLabel(EthereumAddress account) async {
    try {
      final all = await PublicOSXmtp.getAllAccountInboxIds(account);
      if (all == null) return null;
      final taken = all.labels.map((l) => l.toLowerCase()).toSet();
      // The KEY's own name first: the user already chose it
      // when they made the key, and it is the name the Inbox IDs page offers,
      // so the two register surfaces propose the same thing. Sanitised
      // to the contract charset, since key labels have no such limit.
      final keyLabel = _sanitiseLabel(PublicOS.currentXmtpKeyLabel);
      if (keyLabel != null && !taken.contains(keyLabel)) return keyLabel;
      return taken.contains(_kDefaultInboxLabel) ? null : _kDefaultInboxLabel;
    } catch (_) {
      return null;
    }
  }

  /// A keychain key label squeezed into `XmtpManager._validateLabel`'s
  /// charset: lowercase, `[a-z0-9._-]`, 1..31 bytes, first char `[a-z0-9_]`.
  /// Returns null when nothing usable survives (e.g. a key named `***`).
  static String? _sanitiseLabel(String? raw) {
    if (raw == null) return null;
    var out = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]'), '');
    out = out.replaceAll(RegExp(r'^[.-]+'), '');
    if (out.length > 31) out = out.substring(0, 31);
    return out.isEmpty ? null : out;
  }

  Future<void> _editKeyLabel(String currentLabel) async {
    final TextEditingController labelController = TextEditingController(text: currentLabel);

    final String? newLabel = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.m),
        title: Text(context.l10n.keychainEditTitle),
        content: TextField(
          controller: labelController,
          decoration: InputDecoration(
            labelText: context.l10n.keychainKeyLabel,
            hintText: context.l10n.keychainEditHint,
          ),
          maxLength: 50,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.dlgCancel),
          ),
          TextButton(
            onPressed: () {
              final label = labelController.text.trim();
              if (label.isNotEmpty && label != currentLabel) {
                Navigator.pop(context, label);
              } else {
                Navigator.pop(context);
              }
            },
            child: Text(context.l10n.keychainSave),
          ),
        ],
      ),
    );

    if (newLabel == null || newLabel.isEmpty || newLabel == currentLabel) return;

    try {
      setState(() => _isLoading = true);

      final currentUserAddress = AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
      if (currentUserAddress == null) {
        _setErrorMsg((l) => l.errNoUserAddress);
        return;
      }

      await PublicOSKeychain.updateKeyLabel(currentUserAddress, currentLabel, newLabel);

      // Update selection state if this was the selected key
      if (_currentSelectedKey == currentLabel) {
        _currentSelectedKey = newLabel;
      }

      _snackMsg((l) => l.keychainLabelUpdated);
      _fetchKeys();
    } catch (e) {
      _setError(e);
    }
  }

  Future<void> _toggleWallet(String label, bool currentState) async {
    try {
      final currentUserAddress = AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
      if (currentUserAddress == null) {
        _snackMsg((l) => l.errNoUserAddress);
        return;
      }

      setState(() => _isLoading = true);

      await PublicOSKeychain.setWalletEnabled(currentUserAddress, label, !currentState);

      _snackMsg((l) => !currentState
          ? l.keychainWalletEnabled(label)
          : l.keychainWalletDisabled(label));
      _fetchKeys();

      // Notify parent that keys have changed
      widget.onKeysChanged?.call();
    } catch (e) {
      _snackError(e);
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Select a key for web/signing
  /// Pass 'session' for session key, or key label for keychain keys
  Future<void> _selectWebKey(String label) async {
    try {
      final currentUserAddress = AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
      if (currentUserAddress == null) {
        _snackMsg((l) => l.errNoUserAddress);
        return;
      }

      await PublicOSKeychain.setWebSelectedKey(currentUserAddress, label);

      if (mounted) {
        setState(() {
          _webSelectedKey = label;
        });
      }

      _snackMsg((l) =>
          l.keychainWebKeySet(label == 'session' ? l.keychainSessionKey : label));

      // Notify parent that keys have changed
      widget.onKeysChanged?.call();
    } catch (e) {
      _snackError(e);
    }
  }

  Future<void> _showEmojiPicker(String label, String currentEmoji) async {
    final emoji = await showEmojiPickerDialog(
      context,
      currentEmoji: currentEmoji,
    );
    if (emoji != null) await _updateKeyEmoji(label, emoji);
  }

  Future<void> _updateKeyEmoji(String label, String newEmoji) async {
    try {
      final currentUserAddress = AppStateNotifier.currentMyContact?.publicosAddress?.eip55With0x;
      if (currentUserAddress == null) {
        _snackMsg((l) => l.errNoUserAddress);
        return;
      }

      setState(() => _isLoading = true);

      await PublicOSKeychain.setKeyEmoji(currentUserAddress, label, newEmoji);

      _snackMsg((l) => l.keychainEmojiUpdated(label));
      _fetchKeys();

      // Notify parent that keys have changed
      widget.onKeysChanged?.call();
    } catch (e) {
      _snackError(e);
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  Widget _buildStatusRow({
    required BuildContext context,
    required String label,
    required String value,
    required VoidCallback onCopy,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha:0.6),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.copy, size: 16),
          tooltip: context.l10n.keychainCopyTooltip(label),
          onPressed: onCopy,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;

    return Container(
      height: MediaQuery.of(context).size.height * 0.8,
      decoration: BoxDecoration(
        color: tokens.surfaceDeep,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Drag handle
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: tokens.borderMedium,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _contextLabel(l10n),
                        key: widget.tourTitleKey,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _contextSubtitle(l10n),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha:0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                // Refresh: re-reads every key's inbox from the network, so a
                // key moved to another inbox (the QR handoff) stops showing
                // its old one, and reloads the active key if it moved.
                if (widget.type == KeychainType.xmtp)
                  IconButton(
                    tooltip: l10n.keychainRefresh,
                    onPressed: _refreshingKeys ? null : _refreshKeys,
                    icon: _refreshingKeys
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: PixelRainLoadingWidget(size: 20),
                          )
                        : Icon(Icons.refresh_rounded,
                            color: tokens.starkWhite, size: 22),
                  ),
                Icon(
                  Icons.vpn_key,
                  color: theme.colorScheme.primary,
                  size: 32,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Content
          Expanded(
            child: _isLoading
                ? const Center(child: PixelRainLoadingWidget(size: 32, showShadows: false))
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.error_outline,
                                size: 48,
                                color: Colors.red.withValues(alpha:0.7),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 16),
                              ElevatedButton(
                                onPressed: _fetchKeys,
                                child: Text(l10n.actionRetry),
                              ),
                            ],
                          ),
                        ),
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Session Key Section
                            KeyedSubtree(
                              key: widget.tourSessionKey,
                              child: _buildSessionKeyTile(theme),
                            ),
                            const SizedBox(height: 16),

                            // No divider: spacing separates instead.
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 40),
                              child: const SizedBox(
                                height: 8,
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Keychain Keys Section
                            if (_keys.isEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 32),
                                child: Center(
                                  child: Column(
                                    children: [
                                      Icon(
                                        Icons.key_off,
                                        size: 40,
                                        color: theme.colorScheme.onSurface.withValues(alpha:0.3),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        l10n.keychainNoKeys,
                                        style: theme.textTheme.bodyMedium?.copyWith(
                                          color: theme.colorScheme.onSurface.withValues(alpha:0.6),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            else
                              ...List.generate(_keys.length, (index) {
                                final key = _keys[index];
                                final isActive = key['label'] == _currentSelectedKey;
                                // The tour spotlights the first key it can
                                // actually ACTIVATE — never simply the first
                                // row. The current key's SIM has no handler
                                // (`quickOnTap` is null when `isCurrentKey`),
                                // so on a second run through the flow the
                                // spotlight landed on a dead control while the
                                // live one sat outside the hole, blocked by
                                // the scrim. `-1` when every key is active
                                // attaches the anchor to nothing, and the coach
                                // then paints nothing — a missing spotlight
                                // beats one pointing at a button that cannot
                                // be pressed.
                                final isSimTarget = index ==
                                    _keys.indexWhere((k) =>
                                        k['label'] != _currentSelectedKey);
                                return Padding(
                                  padding: EdgeInsets.only(bottom: index < _keys.length - 1 ? 12 : 0),
                                  child: _buildKeyTile(
                                    key,
                                    isCurrentKey: isActive,
                                    isSimTarget: isSimTarget,
                                  ),
                                );
                              }),
                          ],
                        ),
                      ),
          ),
          // Bottom action buttons
          Container(
            padding: const EdgeInsets.all(24),
            // No rule above the buttons (borderless).
            decoration: const BoxDecoration(),
            child: widget.onboardingMode == KeychainOnboardingMode.activate
                // Activate mode (XMTP onboarding step): no create/import — the
                // user just picks an existing key via its SIM action.
                ? Row(
                    children: [
                      Icon(Icons.sim_card_rounded,
                          size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          l10n.keychainActivateHint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      // Import Key button — hidden in onboarding modes so a
                      // brand-new user can only Generate their first key.
                      if (widget.onboardingMode ==
                          KeychainOnboardingMode.off) ...[
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _showImportSheet,
                            icon: const Icon(Icons.download),
                            label: Text(l10n.keychainImport),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                      // Generate New Key button
                      Expanded(
                        child: ElevatedButton.icon(
                          key: widget.tourGenerateKey,
                          onPressed: _generateNewKey,
                          icon: const Icon(Icons.add_circle_outline),
                          label: Text(l10n.keychainGenerate),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// Build the session key tile (shown at top of list)
  Widget _buildSessionKeyTile(ThemeData theme) {
    final currentContact = AppStateNotifier.currentMyContact;
    final address = PublicOS.sessionBlockchainAddress ?? '0x0000...0000';
    final isWebSelected = _webSelectedKey == null || _webSelectedKey == 'session';

    // The session key is a key like any other and behaves like one: a
    // chevron, and its settings (Export among them) in the panel underneath,
    // so the row reads the same as every other key's.
    // `'session'` is the accordion id, the same sentinel the rest of the
    // codebase already uses for this key (`_selectWebKey('session')`, a grant's
    // `keyLabel`).
    final controller = _getOrCreateController('session');
    final expandAnim = _expandAnims['session'];

    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _toggleExpanded('session'),
                  child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha:0.5),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Contact icon
                currentContact != null
                    ? GlassContactIcon(
                        contact: currentContact,
                        size: 44,
                      )
                    : Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.account_circle_rounded,
                          color: theme.colorScheme.onSurfaceVariant,
                          size: 28,
                        ),
                      ),
                const SizedBox(width: 12),
                // Name and address
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              currentContact?.displayName ?? context.l10n.keychainMyAccount,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            context.l10n.keychainSessionBadge,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            shortenString(address, isAddress: true),
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              color: theme.colorScheme.onSurface.withValues(alpha:0.5),
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: () => _copyToClipboard(address),
                            child: Icon(
                              Icons.copy_rounded,
                              size: 13,
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                            ),
                          ),
                        ],
                      ),
                      // This key's lifetime.
                      KeyLifetimeLine(
                        sessionAddress: address,
                        showPermanent: true,
                        shadow: false,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ],
                  ),
                ),
                // Action buttons
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _RowIconButton(
                      icon: isWebSelected
                          ? Icons.public_rounded
                          : Icons.public_outlined,
                      primary: isWebSelected,
                      onTap: () => _selectWebKey('session'),
                      tokens: GlassTokens.of(context),
                    ),
                    const SizedBox(width: 4),
                    AnimatedBuilder(
                      animation: controller,
                      builder: (context, _) => Transform.rotate(
                        angle: controller.value * 1.5708,
                        child: _RowIconButton(
                          icon: Icons.expand_more_rounded,
                          onTap: () => _toggleExpanded('session'),
                          tokens: GlassTokens.of(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
        if (expandAnim != null)
          SizeTransition(
            sizeFactor: expandAnim,
            alignment: Alignment.topCenter,
            child: _buildSessionKeyExpandedSection(),
          ),
      ],
    );
  }

  /// The session key's panel. Deliberately short: this key cannot be renamed,
  /// re-emoji'd or deleted, and its XMTP/web pointers are quick actions on the
  /// row -- so what is left is Export and the apps it
  /// is connected to.
  Widget _buildSessionKeyExpandedSection() {
    final tokens = GlassTokens.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tokens.surfaceDeep.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildKeyGrants(null),
          const SizedBox(height: 6),
          const SizedBox(height: 2),
          const SizedBox(height: 6),
          _KeychainActionRow(
            icon: Icons.upload_rounded,
            label: context.l10n.keychainActionExport,
            subtitle: context.l10n.keychainActionExportSub,
            onTap: _exportSessionKey,
            tokens: tokens,
          ),
        ],
      ),
    );
  }

  /// Export the session key
  void _exportSessionKey() {
    final privateKey = PublicOS.currentBlockchainPrivateKey;
    if (privateKey == null) {
      _showSnackBar(context.l10n.keychainSessionKeyUnavail);
      return;
    }

    final privateKeyHex = '0x${privateKey.privateKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    // Session key has no stored mnemonic in this surface — export hex only.
    showExportKeyDialog(
      context,
      mnemonic: null,
      privateKey: privateKeyHex,
      keyLabel: context.l10n.keychainSessionKey,
    );
  }

  Widget _buildKeyTile(Map<String, dynamic> key,
      {bool isCurrentKey = false, bool isSimTarget = false}) {
    final tokens = GlassTokens.of(context);
    final label = key['label'] ?? context.l10n.keychainUnnamedKey;
    final address = key['address'] ?? context.l10n.keychainUnknownAddr;
    final isWebSelected = _webSelectedKey == label;
    final emoji = key['emoji'] ?? '🔑';
    final isExpanded = _expandedLabel == label;
    final controller = _getOrCreateController(label);
    final expandAnim = _expandAnims[label];

    // Quick action depends on the sheet's type. In XMTP view the quick
    // button selects this key as the current XMTP key; in web view it
    // sets this key as the current web-signing key. The *other* pointer
    // is a toggle inside the expanded drawer.
    final isQuickActive = widget.type == KeychainType.xmtp
        ? isCurrentKey
        : isWebSelected;
    final quickIcon = widget.type == KeychainType.xmtp
        ? (isCurrentKey ? Icons.sim_card_rounded : Icons.sim_card_outlined)
        : (isWebSelected ? Icons.public_rounded : Icons.public_outlined);
    // In onboarding "create" mode the SIM (load-into-XMTP) action is disabled —
    // keys are only created here; the user activates one later on the XMTP step.
    final VoidCallback? quickOnTap =
        widget.onboardingMode == KeychainOnboardingMode.create
            ? null
            : widget.type == KeychainType.xmtp
                // The loaded key's sim unloads it (not during onboarding,
                // where the flow is about getting one loaded).
                ? (isCurrentKey
                    ? (widget.onboardingMode == KeychainOnboardingMode.off
                        ? _unloadKey
                        : null)
                    : () => _selectKey(label, key['privateKey'] ?? ''))
                : (isWebSelected ? null : () => _selectWebKey(label));

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              // The FILL carries expansion — a tone step up when open.
              color: isExpanded ? tokens.surfaceElevated : tokens.glassFill,
              borderRadius: BorderRadius.circular(14),
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _toggleExpanded(label),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      // Emoji avatar — tap still opens emoji picker for quick
                      // access; the expanded drawer also has a "Change emoji"
                      // row for discoverability.
                      GestureDetector(
                        onTap: () => _showEmojiPicker(label, emoji),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: tokens.surfaceElevated,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Text(
                              emoji,
                              style: const TextStyle(fontSize: 22),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              label,
                              style: TextStyle(
                                fontFamily: 'SpaceGrotesk',
                                color: tokens.starkWhite,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.2,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_inboxAddressByKey[label] != null) ...[
                                  Flexible(
                                    child: Text(
                                      _inboxAddressByKey[label]!.isEmpty
                                          ? context.l10n.statusBarInboxUnregistered
                                          : _inboxAddressByKey[label]!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 10,
                                        color: tokens.textDim,
                                      ),
                                    ),
                                  ),
                                  Text('  ·  ',
                                      style: TextStyle(fontSize: 10, color: tokens.textDim)),
                                ],
                                Text(
                                  shortenString(address, isAddress: true),
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 10,
                                    letterSpacing: 0.3,
                                    color: tokens.textDim,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                GestureDetector(
                                  onTap: () => _copyToClipboard(address),
                                  child: Icon(
                                    Icons.copy_rounded,
                                    size: 12,
                                    color: tokens.textDim,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      // Quick action + expand chevron
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _RowIconButton(
                            // The tour spotlights the SIM on the FIRST key
                            // row — during the coach sequence there is exactly
                            // one, the key just generated. Null in every other
                            // mode, so no key is attached and nothing changes.
                            key: isSimTarget ? widget.tourSimKey : null,
                            icon: quickIcon,
                            primary: isQuickActive,
                            onTap: quickOnTap,
                            tokens: tokens,
                          ),
                          const SizedBox(width: 4),
                          AnimatedBuilder(
                            animation: controller,
                            builder: (context, _) {
                              return Transform.rotate(
                                angle: controller.value * 1.5708,
                                child: _RowIconButton(
                                  icon: Icons.expand_more_rounded,
                                  onTap: () => _toggleExpanded(label),
                                  tokens: tokens,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (expandAnim != null)
            SizeTransition(
              sizeFactor: expandAnim,
              axisAlignment: -1,
              child: _buildKeyExpandedSection(key, isCurrentKey, tokens),
            ),
        ],
      ),
    );
  }

  /// The drawer content that unfolds under a key row on expand.
  ///
  /// Shows toggles (select-the-other-pointer + wallet-enabled) and
  /// action rows (emoji / rename / export / delete). The "other" select
  /// pointer rotates by `widget.type` — xmtp view exposes the web toggle
  /// and vice versa, because the same pointer as the quick action button
  /// would be redundant.
  Widget _buildKeyExpandedSection(
    Map<String, dynamic> key,
    bool isCurrentKey,
    GlassTokens tokens,
  ) {
    final label = key['label'] ?? context.l10n.keychainUnnamedKey;
    final isWebSelected = _webSelectedKey == label;
    final walletEnabled = key['walletEnabled'] == true;

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tokens.surfaceDeep.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Pointer the OTHER direction — hidden for whichever selection
          // the quick action already surfaces.
          if (widget.type == KeychainType.web)
            _KeychainToggleRow(
              icon: Icons.sim_card_outlined,
              label: context.l10n.keychainToggleXmtpKey,
              subtitle: context.l10n.keychainToggleXmtpSub,
              value: isCurrentKey,
              onChanged: isCurrentKey
                  ? (widget.onboardingMode == KeychainOnboardingMode.off
                      ? (_) => _unloadKey()
                      : null)
                  : (_) => _selectKey(label, key['privateKey'] ?? ''),
              tokens: tokens,
            ),
          if (widget.type == KeychainType.xmtp)
            _KeychainToggleRow(
              icon: Icons.public_outlined,
              label: context.l10n.keychainToggleWebKey,
              subtitle: context.l10n.keychainToggleWebSub,
              value: isWebSelected,
              onChanged: isWebSelected ? null : (_) => _selectWebKey(label),
              tokens: tokens,
            ),
          _KeychainToggleRow(
            icon: Icons.account_balance_wallet_outlined,
            label: context.l10n.keychainToggleWallet,
            subtitle: context.l10n.keychainToggleWalletSub,
            value: walletEnabled,
            onChanged: (_) => _toggleWallet(label, walletEnabled),
            tokens: tokens,
          ),
          _buildKeyGrants(key['address'] as String?),
          const SizedBox(height: 6),
          const SizedBox(height: 2),
          const SizedBox(height: 6),
          _KeychainActionRow(
            icon: Icons.emoji_emotions_outlined,
            label: context.l10n.keychainActionEmoji,
            subtitle: context.l10n.keychainActionEmojiSub,
            onTap: () => _showEmojiPicker(label, key['emoji'] ?? '🔑'),
            tokens: tokens,
          ),
          _KeychainActionRow(
            icon: Icons.edit_outlined,
            label: context.l10n.keychainActionRename,
            subtitle: context.l10n.keychainActionRenameSub,
            onTap: () => _editKeyLabel(label),
            tokens: tokens,
          ),
          _KeychainActionRow(
            icon: Icons.upload_rounded,
            label: context.l10n.keychainActionExport,
            subtitle: context.l10n.keychainActionExportSub,
            onTap: () => _exportPrivateKeyAsInt(label),
            tokens: tokens,
          ),
          if (widget.type == KeychainType.xmtp)
            _KeychainActionRow(
              icon: Icons.qr_code_2_rounded,
              label: context.l10n.keychainActionAddToInbox,
              subtitle: context.l10n.keychainActionAddToInboxSub,
              onTap: () => _showKeyQr(label),
              tokens: tokens,
            ),
          _KeychainActionRow(
            icon: Icons.delete_outline_rounded,
            label: context.l10n.keychainActionDelete,
            subtitle: context.l10n.keychainActionDeleteSub,
            destructive: true,
            onTap: () => _deleteKey(label),
            tokens: tokens,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Row-local helpers — keep the expand/collapse look consistent with
// manage_inbox_ids_page.dart so both surfaces feel like the same widget
// family.
// ---------------------------------------------------------------------------

class _RowIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool primary;
  final bool destructive;
  final GlassTokens tokens;

  const _RowIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    required this.tokens,
    this.primary = false,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    const size = 34.0;
    const iconSize = 16.0;
    final bg = primary
        ? tokens.connectedAccent.withValues(alpha: 0.2)
        : destructive
            ? tokens.fallbackAccent.withValues(alpha: 0.12)
            : tokens.glassFill;
    final fg = primary
        ? tokens.connectedAccent
        : destructive
            ? tokens.fallbackAccent
            : (onTap == null
                ? tokens.starkWhite.withValues(alpha: 0.35)
                : tokens.starkWhite);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: size,
          height: size,
          // `bg` and `fg` already say primary / destructive / neutral; the
          // ring said it a third time.
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: iconSize, color: fg),
        ),
      ),
    );
  }
}

class _KeychainToggleRow extends StatelessWidget {
  final IconData? icon;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final GlassTokens tokens;

  const _KeychainToggleRow({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.tokens,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 18, color: tokens.starkWhite),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    color: tokens.starkWhite,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    color: tokens.textDim,
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeColor: tokens.connectedAccent,
          ),
        ],
      ),
    );
  }
}

class _KeychainActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  final bool destructive;
  final GlassTokens tokens;

  const _KeychainActionRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
    required this.tokens,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = destructive ? tokens.fallbackAccent : tokens.starkWhite;
    final subFg = destructive
        ? tokens.fallbackAccent.withValues(alpha: 0.7)
        : tokens.textDim;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              Icon(icon, color: fg, size: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        color: fg,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        color: subFg,
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: subFg,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A connected app's favicon, with a fixed 28px footprint across loading and
/// error so a row never reflows while the network answers.
///
/// The URL is Google's favicon service (`FaviconUtils`), the same rung the
/// browser's web tabs already use -- so opening the keychain sends one
/// request per connected app to Google, naming hosts the user has connected to.
/// Same trade-off already accepted for web tabs; worth knowing it applies here.
class _SiteFavicon extends StatelessWidget {
  final String origin;
  final GlassTokens tokens;

  const _SiteFavicon({required this.origin, required this.tokens});

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(Icons.public_rounded, size: 15, color: tokens.textDim);
    return SizedBox(
      width: 28,
      height: 28,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: ZeroCachedImage(
          imageUrl: FaviconUtils.getFaviconUrl(origin),
          fit: BoxFit.cover,
          placeholder: (_, __) => Center(child: fallback),
          errorWidget: (_, __, ___) => Center(child: fallback),
        ),
      ),
    );
  }
}
