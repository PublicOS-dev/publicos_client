import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:publicos_core/publicos_core.dart';

import 'package:publicos_client/components/pixel_rain_loading_label.dart';
import 'package:publicos_client/components/feeds/discover_contact_row.dart';
import 'package:publicos_client/components/glass_contact_icon.dart';
import 'package:publicos_client/components/grid_settings_sheet.dart';
import 'package:publicos_client/components/glass_context_menu.dart';
import 'package:publicos_client/components/send_icon.dart';
import 'package:publicos_client/components/transactions/send_sheet.dart';
import 'package:publicos_client/components/explorer/chip_bar.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/cupertino.dart';
import 'package:publicos_client/pages/create_org_page.dart';
import 'package:publicos_client/router_helpers.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';

/// Sort axes for the contacts grid.
enum ContactSort { nameAsc, nameDesc }

/// Contacts tab — glass grid with 2-line name wrap, Personal/Orgs filter
/// chips, A-Z/Z-A sort chips, and a New Org action chip. Direct Core
/// (`PublicOSContacts`) with setState — no repo.
///
/// Also: long-press context menu → delete, search resolution via
/// `resolveByIdentifier`, New Org chip → `CreateOrgPage`.
class ContactsView extends StatefulWidget {
  const ContactsView({super.key});

  @override
  State<ContactsView> createState() => _ContactsViewState();
}

/// On-chain "publicos" group account, hardcoded so the settings-sheet
/// preview always points at the canonical brand contact (same address the
/// feeds reading-settings preview uses).
///
/// ⚠️ ROOT-ORG COUPLED, NOT RESOLVER-PINNED — dies with every chain redeploy,
/// and a stale value fails SILENTLY (default avatar, no error). Keep in
/// lockstep with `feeds_settings_sheet.dart`'s `_publicosAccountAddress`; both
/// re-point from `MR.getModuleAddress(keccak256("PUBLICOS_ROOT_ORG"))`.
const String _previewContactAddress =
    '0x814f894Eb8F1B36b615baeCB7c4a35eBACa739bD';

class _ContactsViewState extends State<ContactsView> {
  // Grid/text density (shared with Apps tab via explorer_grid_size /
  // explorer_text_size keys).
  int _gridSize = kDefaultGridSize;
  TextSizeOption _textSize = kDefaultTextSize;

  // Contacts-only layout state. Persisted under contacts_layout /
  // contacts_show_contact_banner — kept separate so Apps grid stays unaffected.
  ContactsLayout _layout = ContactsLayout.rows;
  bool _showBanner = true;

  // Contact state
  List<Contact> _all = const [];
  Contact? _searchResult;
  bool _isLoading = true;
  bool _isSearching = false;
  String? _error;
  int _loadGeneration = 0;

  // Filter / sort / search state
  bool _showPersonal = true;
  bool _showOrgs = true;
  ContactSort _sort = ContactSort.nameAsc;
  String _query = '';

  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
    _loadStoredSettings();
    _loadContacts();
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Pull the stored grid + text size from Core (shared with the Apps tab
  /// via the same `explorer_grid_size` / `explorer_text_size` keys), plus
  /// the Contacts-only `contacts_layout` + `contacts_show_contact_banner`
  /// preferences. Silent no-op pre-auth.
  Future<void> _loadStoredSettings() async {
    final results = await Future.wait([
      loadStoredGridSize(),
      loadStoredTextSize(),
      loadStoredContactsLayout(),
      loadStoredContactsShowBanner(),
    ]);
    if (!mounted) return;
    setState(() {
      final grid = results[0] as int?;
      final text = results[1] as TextSizeOption?;
      final layout = results[2] as ContactsLayout?;
      final showBanner = results[3] as bool?;
      if (grid != null) _gridSize = grid;
      if (text != null) _textSize = text;
      if (layout != null) _layout = layout;
      if (showBanner != null) _showBanner = showBanner;
    });
  }

  /// Initial + manual refresh. Loads stored contacts, drops zero-address
  /// entries and the current user. Pre-auth silently no-ops.
  Future<void> _loadContacts({bool showSpinner = true}) async {
    final gen = ++_loadGeneration;
    if (showSpinner) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      final myAddr = PublicOS.myPublicosAddress?.toLowerCase();
      final loaded = await PublicOSContacts.getStoredContacts();
      if (gen != _loadGeneration || !mounted) return;

      const zero = '0x0000000000000000000000000000000000000000';
      final filtered = loaded.where((c) {
        final addr = c.publicosAddress?.eip55With0x.toLowerCase();
        if (addr == null) return false;
        if (addr == zero) return false;
        if (myAddr != null && addr == myAddr) return false;
        return true;
      }).toList();

      setState(() {
        _all = filtered;
        _isLoading = false;
        _error = null;
      });
    } catch (e) {
      if (gen != _loadGeneration || !mounted) return;
      final l10n = context.l10n;
      setState(() {
        _all = const [];
        _error = localizedError(l10n, e);
        _isLoading = false;
      });
    }
  }

  /// Pull-to-refresh hook — same as [_loadContacts] but doesn't flip
  /// `_isLoading` so the grid keeps rendering during the refresh.
  Future<void> _refresh() => _loadContacts(showSpinner: false);

  void _onSearchChanged() {
    final next = _searchCtrl.text;
    if (next == _query) return;
    setState(() => _query = next);
    _handleSearchResolution();
  }

  /// When the local filter would come up empty but the user typed a real
  /// identifier (address / inbox / on-chain name), reach to Core and surface
  /// the match as a single result card prepended to the grid.
  Future<void> _handleSearchResolution() async {
    final trimmed = _query.trim();
    if (trimmed.isEmpty) {
      if (_searchResult != null || _isSearching) {
        setState(() {
          _searchResult = null;
          _isSearching = false;
        });
      }
      return;
    }

    setState(() => _isSearching = true);
    try {
      final resolved = await PublicOSContacts.resolveByIdentifier(trimmed);
      if (!mounted) return;
      if (resolved == null) {
        setState(() {
          _searchResult = null;
          _isSearching = false;
        });
        return;
      }

      // Suppress if already in the local list (by address or inbox).
      final resolvedInbox = resolved.registeredInboxIDs?.firstOrNull?.inboxId;
      final alreadyLocal = _all.any((c) {
        final byAddress = c.publicosAddress != null &&
            c.publicosAddress == resolved.publicosAddress;
        final byInbox = resolvedInbox != null &&
            (c.registeredInboxIDs?.any((e) => e.inboxId == resolvedInbox) ??
                false);
        return byAddress || byInbox;
      });

      setState(() {
        _searchResult = alreadyLocal ? null : resolved;
        _isSearching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searchResult = null;
        _isSearching = false;
      });
    }
  }

  // ---- filter mutators (guard against both-off) -----------------------------

  void _setShowPersonal(bool value) {
    if (_showPersonal == value) return;
    setState(() {
      if (!value && !_showOrgs) _showOrgs = true;
      _showPersonal = value;
    });
  }

  void _setShowOrgs(bool value) {
    if (_showOrgs == value) return;
    setState(() {
      if (!value && !_showPersonal) _showPersonal = true;
      _showOrgs = value;
    });
  }

  void _setSort(ContactSort value) {
    if (_sort == value) return;
    setState(() => _sort = value);
  }

  // ---- derived view ---------------------------------------------------------

  // Memoized filter+sort output. Recomputed lazily by [_filteredContacts]
  // when any of its 6 inputs changes since the last computation. Avoids
  // re-running `compareTo` for every contact pair on every parent build
  // (keep-alive pings, child image loads, etc.).
  List<Contact>? _cachedFiltered;
  List<Contact>? _filteredKeyAll;
  Contact? _filteredKeySearchResult;
  String? _filteredKeyQuery;
  bool? _filteredKeyShowPersonal;
  bool? _filteredKeyShowOrgs;
  ContactSort? _filteredKeySort;

  List<Contact> get _filteredContacts {
    if (_cachedFiltered != null &&
        identical(_filteredKeyAll, _all) &&
        identical(_filteredKeySearchResult, _searchResult) &&
        _filteredKeyQuery == _query &&
        _filteredKeyShowPersonal == _showPersonal &&
        _filteredKeyShowOrgs == _showOrgs &&
        _filteredKeySort == _sort) {
      return _cachedFiltered!;
    }

    Iterable<Contact> view = _all;

    if (!_showPersonal || !_showOrgs) {
      view = view.where((c) {
        final isOrg = c.isOrgAccount;
        if (isOrg && !_showOrgs) return false;
        if (!isOrg && !_showPersonal) return false;
        return true;
      });
    }

    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      view = view.where((c) {
        if (c.displayName.toLowerCase().contains(q)) return true;
        if (c.publicosDisplayName?.toLowerCase().contains(q) == true) {
          return true;
        }
        if (c.publicosAddress?.eip55With0x.toLowerCase().contains(q) == true) {
          return true;
        }
        final inboxHit = c.registeredInboxIDs
                ?.any((e) => e.inboxId.toLowerCase().contains(q)) ??
            false;
        if (inboxHit) return true;
        final sessionHit = c.sessions
                ?.any((cl) =>
                    cl.address.eip55With0x.toLowerCase().contains(q)) ??
            false;
        return sessionHit;
      });
    }

    final list = view.toList();
    list.sort((a, b) {
      final cmp = a.displayName
          .toLowerCase()
          .compareTo(b.displayName.toLowerCase());
      return _sort == ContactSort.nameAsc ? cmp : -cmp;
    });

    // Prepend the resolved search hit when we have one and the query is
    // still non-empty.
    if (_searchResult != null && _query.trim().isNotEmpty) {
      list.insert(0, _searchResult!);
    }

    _cachedFiltered = list;
    _filteredKeyAll = _all;
    _filteredKeySearchResult = _searchResult;
    _filteredKeyQuery = _query;
    _filteredKeyShowPersonal = _showPersonal;
    _filteredKeyShowOrgs = _showOrgs;
    _filteredKeySort = _sort;
    return list;
  }

  // ---- actions --------------------------------------------------------------

  void _openSettings() {
    showGridSettingsSheet(
      context,
      currentGridSize: _gridSize,
      currentTextSize: _textSize,
      onGridSizeChanged: (v) => setState(() => _gridSize = v),
      onTextSizeChanged: (v) => setState(() => _textSize = v),
      showLayoutToggle: true,
      currentLayout: _layout,
      onLayoutChanged: (v) => setState(() => _layout = v),
      showBannerToggle: true,
      currentShowBanner: _showBanner,
      onShowBannerChanged: (v) => setState(() => _showBanner = v),
      showContactPreview: true,
      previewContactAddress: _previewContactAddress,
    );
  }

  void _handleTap(Contact contact) {
    AppNav.toContact(context, contact);
  }

  void _showContactContextMenu(Contact contact, Offset globalPosition) {
    final address = contact.publicosAddress?.eip55With0x;
    final l10n = context.l10n;
    GlassContextMenu.show(
      context,
      position: globalPosition,
      // The browser pills' glass, like the profile "…" menu.
      frosted: true,
      items: [
        // Send to this contact: the one known recipient skips to the amount,
        // and the sheet's target defaults to their Main Safe.
        if (contact.publicosAddress != null)
          GlassContextMenuItem(
            iconBuilder: (size, color) =>
                SendCoinsIcon(size: size, color: color),
            label: l10n.contactsViewSend,
            onTap: () => showSendSheet(
              context: context,
              config: SendSheetConfig(
                targetMode: SendTargetMode.fixed,
                candidates: [
                  SendCandidate(
                    address: contact.publicosAddress!,
                    contact: contact,
                  ),
                ],
              ),
            ),
          ),
        // Same link the profile's share button copies — the publicos.dev
        // universal link the app resolves back into a profile.
        if (address != null)
          GlassContextMenuItem(
            icon: Icons.share_outlined,
            label: l10n.contactsViewShare,
            onTap: () =>
                Share.share('https://publicos.dev/publicosAddress/$address'),
          ),
        GlassContextMenuItem(
          icon: Icons.delete_outline_rounded,
          label: l10n.contactsViewDelete,
          destructive: true,
          onTap: () => _confirmDeleteContact(contact),
        ),
      ],
    );
  }

  /// Destructive-tier glass confirm before the delete.
  Future<void> _confirmDeleteContact(Contact contact) async {
    final tokens = GlassTokens.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
        backgroundColor: tokens.surfaceDeep,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: tokens.borderSubtle),
        ),
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: errorColor, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.contactsViewDeleteContactTitle,
                style: TextStyle(
                  fontFamily: 'SpaceGrotesk',
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                  color: errorColor,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          l10n.contactsViewDeleteConfirm(contact.displayName),
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            fontSize: 14,
            color: tokens.textDim,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.dlgCancel, style: TextStyle(color: tokens.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child:
                Text(l10n.contactsViewDelete, style: TextStyle(color: errorColor)),
          ),
        ],
      ),
    );
    if (confirmed == true) await _deleteContact(contact);
  }

  Future<void> _deleteContact(Contact contact) async {
    final l10n = context.l10n;
    try {
      await PublicOSContacts.removeContact(contact);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(l10n.contactsViewRemovedFromContacts(contact.displayName)),
        ),
      );
      await _loadContacts(showSpinner: false);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.contactsViewFailedToRemove)),
      );
    }
  }

  Future<void> _showCreateOrgSheet() async {
    // CreateOrgPage is a pure imperative route: it pops with the new org's
    // address on success, or null if dismissed.
    final orgAddress = await Navigator.of(context).push<String>(
      CupertinoPageRoute(builder: (_) => const CreateOrgPage()),
    );
    if (orgAddress == null || !mounted) return;
    // New org created — open its profile just like tapping a contact. The
    // browser resolves + persists it from chain; refresh the grid when the
    // user pops back so the new org shows up.
    await AppNav.toProfile(context, orgAddress);
    if (!mounted) return;
    _loadContacts(showSpinner: false);
  }

  // ---- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final contacts = _filteredContacts;

    return RefreshIndicator(
      onRefresh: _refresh,
      color: tokens.starkWhite,
      backgroundColor: tokens.surfaceElevated,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // RepaintBoundary so cursor blink + suffix-icon swap stay confined
          // to the search field and don't ripple into the grid.
          SliverToBoxAdapter(
            child: RepaintBoundary(
              child: _SearchField(
                controller: _searchCtrl,
                tokens: tokens,
                isSearching: _isSearching,
              ),
            ),
          ),
          // RepaintBoundary so chip InkWell ripples + active-state animations
          // don't trigger grid repaints.
          SliverToBoxAdapter(
            child: RepaintBoundary(
              child: _ContactsChipBar(
                showPersonal: _showPersonal,
                showOrgs: _showOrgs,
                sort: _sort,
                onTogglePersonal: () => _setShowPersonal(!_showPersonal),
                onToggleOrgs: () => _setShowOrgs(!_showOrgs),
                onSortToggle: () => _setSort(
                  _sort == ContactSort.nameAsc
                      ? ContactSort.nameDesc
                      : ContactSort.nameAsc,
                ),
                onNewOrg: _showCreateOrgSheet,
                onSettings: _openSettings,
              ),
            ),
          ),
          if (_isLoading && _all.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: PixelRainLoadingCorner(),
            )
          else if (_error != null && _all.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _ErrorState(tokens: tokens, message: _error!),
            )
          else if (contacts.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyState(
                tokens: tokens,
                hasQuery: _query.trim().isNotEmpty,
              ),
            )
          else if (_layout == ContactsLayout.rows)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
              sliver: SliverList.builder(
                itemCount: contacts.length,
                itemBuilder: (_, i) => GestureDetector(
                  key: ValueKey(
                    contacts[i].publicosAddress?.eip55With0x ??
                        contacts[i].displayName,
                  ),
                  // Tap goes to the InkWell inside DiscoverContactRow; only
                  // long-press is intercepted here so the row preserves its
                  // ink ripple while still supporting the delete context menu.
                  behavior: HitTestBehavior.translucent,
                  // Haptic fires inside GlassContextMenu.show.
                  onLongPressStart: (details) => _showContactContextMenu(
                    contacts[i],
                    details.globalPosition,
                  ),
                  child: DiscoverContactRow(
                    contact: contacts[i],
                    showBanner: _showBanner,
                    showChevron: false,
                    onTap: () => _handleTap(contacts[i]),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              sliver: SliverLayoutBuilder(
                builder: (context, sliverConstraints) {
                  // Canonical tile geometry — one definition, shared with the
                  // Apps grid and the org member picker. See [GridGeom].
                  final geom = GridGeom.forWidth(
                    sliverConstraints.crossAxisExtent,
                    _gridSize,
                    _textSize,
                  );

                  return SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _gridSize,
                      mainAxisSpacing: GridGeom.gap,
                      crossAxisSpacing: GridGeom.gap,
                      mainAxisExtent: geom.tileH,
                    ),
                    itemCount: contacts.length,
                    itemBuilder: (_, i) => _ContactTile(
                      key: ValueKey(
                        contacts[i].publicosAddress?.eip55With0x ??
                            contacts[i].displayName,
                      ),
                      contact: contacts[i],
                      iconSize: geom.iconSize,
                      fontSize: geom.fontSize,
                      lineHeight: GridGeom.lineHeight,
                      iconToText: GridGeom.iconToText,
                      textBlockH: geom.textBlockH,
                      onTap: () => _handleTap(contacts[i]),
                      onLongPress: (pos) =>
                          _showContactContextMenu(contacts[i], pos),
                      tokens: tokens,
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Search field
// ---------------------------------------------------------------------------

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final GlassTokens tokens;
  final bool isSearching;

  const _SearchField({
    required this.controller,
    required this.tokens,
    required this.isSearching,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          color: tokens.glassFill,
          borderRadius: BorderRadius.circular(12),
        ),
        child: TextField(
          controller: controller,
          style: TextStyle(
              fontFamily: 'SpaceGrotesk',
            color: tokens.starkWhite,
            fontSize: 14,
          ),
          cursorColor: tokens.starkWhite,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 18,
              color: tokens.textDim,
            ),
            suffixIcon: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                if (isSearching) {
                  return Padding(
                    padding: const EdgeInsets.all(10),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        color: tokens.textDim,
                        strokeWidth: 2,
                      ),
                    ),
                  );
                }
                if (value.text.isEmpty) return const SizedBox.shrink();
                return IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: tokens.textDim,
                  ),
                  splashRadius: 16,
                  onPressed: controller.clear,
                );
              },
            ),
            hintText: context.l10n.contactsViewSearchHint,
            hintStyle: TextStyle(
              fontFamily: 'SpaceGrotesk',
              color: tokens.textDim,
              fontSize: 13,
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 12,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Chip bar
// ---------------------------------------------------------------------------

class _ContactsChipBar extends StatelessWidget {
  final bool showPersonal;
  final bool showOrgs;
  final ContactSort sort;
  final VoidCallback onTogglePersonal;
  final VoidCallback onToggleOrgs;
  final VoidCallback onSortToggle;
  final VoidCallback onNewOrg;
  final VoidCallback onSettings;

  const _ContactsChipBar({
    required this.showPersonal,
    required this.showOrgs,
    required this.sort,
    required this.onTogglePersonal,
    required this.onToggleOrgs,
    required this.onSortToggle,
    required this.onNewOrg,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ExplorerChipBar(
      children: [
        ExplorerChip(
          label: l10n.contactsViewFilterPersonal,
          icon: Icons.person_outline_rounded,
          active: showPersonal,
          onTap: onTogglePersonal,
        ),
        const SizedBox(width: 8),
        ExplorerChip(
          label: l10n.contactsViewFilterOrgs,
          icon: Icons.corporate_fare_rounded,
          active: showOrgs,
          onTap: onToggleOrgs,
        ),
        const SizedBox(width: 16),
        ExplorerChip(
          label: sort == ContactSort.nameAsc
              ? l10n.contactsViewSortAsc
              : l10n.contactsViewSortDesc,
          icon: sort == ContactSort.nameAsc
              ? Icons.arrow_upward_rounded
              : Icons.arrow_downward_rounded,
          active: true,
          onTap: onSortToggle,
        ),
        const SizedBox(width: 16),
        ExplorerChip(
          label: l10n.contactsViewNewOrg,
          icon: Icons.add_business_rounded,
          active: false,
          onTap: onNewOrg,
        ),
        const SizedBox(width: 8),
        ExplorerChip(
          label: l10n.contactsViewSettings,
          icon: Icons.tune_rounded,
          active: false,
          onTap: onSettings,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Contact tile
// ---------------------------------------------------------------------------

/// Keep-alive so tiles that scroll out of view aren't disposed and rebuilt —
/// avatar image decode is the dominant per-tile cost and the rebuild was the
/// source of the scroll lag.
class _ContactTile extends StatefulWidget {
  final Contact contact;
  final double iconSize;
  final double fontSize;
  final double lineHeight;
  final double iconToText;
  final double textBlockH;
  final VoidCallback onTap;
  final void Function(Offset globalPosition) onLongPress;
  final GlassTokens tokens;

  const _ContactTile({
    super.key,
    required this.contact,
    required this.iconSize,
    required this.fontSize,
    required this.lineHeight,
    required this.iconToText,
    required this.textBlockH,
    required this.onTap,
    required this.onLongPress,
    required this.tokens,
  });

  @override
  State<_ContactTile> createState() => _ContactTileState();
}

class _ContactTileState extends State<_ContactTile>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // Pre-resolved fields. SliverGrid.builder already wraps each child in a
  // RepaintBoundary (`addRepaintBoundaries: true`), so we don't add another
  // here. The `displayName` is read directly off `widget.contact` (cheap).
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      // Haptic fires inside GlassContextMenu.show.
      onLongPressStart: (details) =>
          widget.onLongPress(details.globalPosition),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          GlassContactIcon(
            contact: widget.contact,
            size: widget.iconSize,
          ),
          SizedBox(height: widget.iconToText),
          SizedBox(
            height: widget.textBlockH,
            // OverflowBox lets the Text lay itself out at its natural height
            // (which includes glyph descenders past the line box) and paint
            // into the row gap below — fixes "y/g/p second line gets clipped"
            // without growing the tile.
            child: OverflowBox(
              minHeight: 0,
              maxHeight: double.infinity,
              alignment: Alignment.topCenter,
              child: Text(
                widget.contact.displayName,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'SpaceGrotesk',
                  color: widget.tokens.starkWhite,
                  fontSize: widget.fontSize,
                  fontWeight: FontWeight.w600,
                  height: widget.lineHeight,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Loading / error / empty states
// ---------------------------------------------------------------------------

class _ErrorState extends StatelessWidget {
  final GlassTokens tokens;
  final String message;
  const _ErrorState({required this.tokens, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 48,
              color: tokens.fallbackAccent,
            ),
            const SizedBox(height: 12),
            Text(
              context.l10n.contactsViewFailedToLoad,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                color: tokens.starkWhite,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                color: tokens.textDim,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final GlassTokens tokens;
  final bool hasQuery;
  const _EmptyState({required this.tokens, required this.hasQuery});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasQuery
                  ? Icons.search_off_rounded
                  : Icons.people_outline_rounded,
              size: 56,
              color: tokens.textDim,
            ),
            const SizedBox(height: 14),
            Text(
              hasQuery
                  ? context.l10n.contactsViewNoMatches
                  : context.l10n.contactsViewNoContactsYet,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                color: tokens.starkWhite,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hasQuery
                  ? context.l10n.contactsViewNoMatchesHint
                  : context.l10n.contactsViewEmptyHint,
              textAlign: TextAlign.center,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                color: tokens.textDim,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
