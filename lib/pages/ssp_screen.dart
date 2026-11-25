import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:publicos_client/components/operator_agreement_sheet.dart';
import 'package:publicos_client/components/glass_contact_icon.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/components/system_app_scaffold.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/pages/manage_server_page.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';

/// SSP page is now a status + connection surface only. Subscription, switch
/// and payment flows live exclusively in Treasury's Network Access card.
/// Here the user sees their currently subscribed SSP (if any), connects to
/// it or to a custom server, registers a new SSP, or adds a custom server.

class SspScreen extends StatefulWidget {
  const SspScreen({super.key});

  @override
  State<SspScreen> createState() => _SspScreenState();
}

class _SspInfo {
  final String slug;
  final String title;
  final String apiUrl;
  final String region;
  final EthereumAddress owner;

  /// V4 gate data — see _BspInfo on bsp_screen.dart for the same shape.
  final BigInt? subscriberCount;
  final BigInt? gateThreshold;
  final bool? gatePaid;

  const _SspInfo({
    required this.slug,
    required this.title,
    required this.apiUrl,
    required this.region,
    required this.owner,
    this.subscriberCount,
    this.gateThreshold,
    this.gatePaid,
  });
}

class _SspScreenState extends State<SspScreen> {
  bool _loading = true;
  String? _error;

  // Server connection status. Source values come from the derived
  // 'ssp' | 'custom' | 'default' | 'unknown' classification done
  // locally in _loadServerStatus — we don't rely on PublicOS.activeSspSource
  // because switchToFeedServer only writes to secure storage, it doesn't
  // refresh that static field until the next initSSP call.
  String _activeSspUrl = '';
  String _sspSource = 'default';
  bool _sspReachable = false;

  // Subscription — kept only for the SUBSCRIBED badge in the providers
  // list and the empty-state copy that varies citizen vs private. There
  // is no Subscription section here (the badge in the providers list
  // already conveys the same fact; payment + switching live in Treasury).
  _SspInfo? _subscribedSsp;
  bool _isCitizen = false;
  // Operator agreement: null = not read (or not a citizen).
  bool? _operatorSigned;
  // Registration allowlist: false = the SSP
  // registry is invite-only and this account is not listed; null = unknown.
  bool? _registrationAllowed;
  // One section open at a time, the Services / Account / Settings accordion.
  String? _openGroup = 'connection';

  // Lists — only the user's owned SSPs (for "MINE" badge) and custom servers
  // are shown. The chain directory of every other SSP moved to Treasury's
  // picker sheet.
  List<_SspInfo> _mySsps = const [];
  List<FeedServerEntry> _customServers = const [];

  // Resolved owner contacts, keyed by lowercased eip55 address. Loaded
  // asynchronously after the SSP lists; nulls mean we tried and got nothing.
  final Map<String, Contact?> _ownerContacts = {};

  @override
  void initState() {
    super.initState();
    _activeSspUrl = PublicOS.activeSspUrl;
    _sspSource = PublicOS.activeSspSource;
    _sspReachable = PublicOS.sspConnected;
    _loadData();
  }

  Future<void> _loadData({bool silent = false}) async {
    if (!silent) {
      if (!mounted) return;
      setState(() => _loading = true);
    }
    try {
      final addrStr = PublicOS.myPublicosAddress;
      if (addrStr == null) {
        if (mounted) {
          setState(() {
            if (!silent) _loading = false;
            _error = context.l10n.sspScreenNoActiveAccount;
          });
        }
        return;
      }
      final addr = EthereumAddress.fromHex(addrStr);

      await _loadSubscription(addr);
      await _loadMySsps(addr);
      await _loadCustomServers();
      await _loadServerStatus();

      if (mounted) {
        setState(() {
          if (!silent) _loading = false;
          _error = null;
        });
      }
      // Owner contacts resolve in background — cards rebuild as they arrive.
      unawaited(_loadOwnerContacts());
    } catch (e) {
      if (mounted) {
        setState(() {
          if (!silent) _loading = false;
          _error = localizedError(context.l10n, e);
        });
      }
    }
  }

  /// Resolve the currently active SSP URL (secure-storage selection →
  /// subscription → custom default → SSP default) and test reachability.
  /// Also derives a local [_sspSource] from the active URL so the header
  /// stays honest after a mid-session switch that hasn't re-run initSSP.
  Future<void> _loadServerStatus() async {
    try {
      final url = await PublicOSSsp.getActiveFeedServerUrl() ??
          PublicOS.DEFAULT_SSP_URL;
      _activeSspUrl = url;
      _sspSource = _classifySource(url);
    } catch (_) {
      _activeSspUrl = PublicOS.DEFAULT_SSP_URL;
      _sspSource = 'default';
    }

    try {
      final health = await PublicOSSsp.checkServerHealth();
      _sspReachable = health.success && (health.data ?? false);
    } catch (_) {
      _sspReachable = false;
    }
  }

  String _classifySource(String url) {
    if (url.isEmpty) return 'default';
    if (_subscribedSsp != null && url == _subscribedSsp!.apiUrl) {
      return 'ssp';
    }
    if (_customServers.any((e) => e.url == url)) return 'custom';
    if (url == PublicOS.DEFAULT_SSP_URL) return 'default';
    return 'unknown';
  }

  Future<void> _loadSubscription(EthereumAddress addr) async {
    try {
      // subs_v2: the assigned SSP slug lives on the one SubsMemory (axis 1).
      final slug = await PublicOSTreasury.assignedSlug(PublicOSTreasury.sspAxis, addr);
      try {
        _isCitizen = await PublicOSAccounts.isCitizen(addr);
        _operatorSigned = _isCitizen ? await _readOperatorSigned(addr) : null;
        _registrationAllowed = _isCitizen ? await PublicOSBsp.canRegisterSsp(addr) : null;
      } catch (_) {
        _isCitizen = false;
      }
      if (slug.isNotEmpty) {
        _subscribedSsp = await _fetchSsp(slug);
      }
    } catch (_) {}
  }

  Future<void> _loadMySsps(EthereumAddress addr) async {
    try {
      final mem = PublicOSBsp.socialServerRegistryMemoryContract;
      final slugs = await mem.getSocialServersByOwner((owner: addr));
      final list = <_SspInfo>[];
      for (final slug in slugs) {
        final info = await _fetchSsp(slug);
        if (info != null) list.add(info);
      }
      _mySsps = list;
    } catch (_) {}
  }

  Future<void> _loadCustomServers() async {
    try {
      final all = await PublicOSSsp.buildFeedServerList();
      _customServers = all.where((e) => e.source == 'custom').toList();
    } catch (_) {
      _customServers = const [];
    }
  }

  Future<void> _loadOwnerContacts() async {
    final owners = <EthereumAddress>{
      ..._mySsps.map((b) => b.owner),
      if (_subscribedSsp != null) _subscribedSsp!.owner,
    };
    for (final owner in owners) {
      final key = owner.eip55With0x.toLowerCase();
      if (_ownerContacts.containsKey(key)) continue;
      Contact? contact;
      try {
        contact = await PublicOSContacts.getContact(owner);
        if (contact == null && PublicOS.web3Connected) {
          contact = await PublicOSContacts.fetchContact(owner, requireRecords: true);
          await PublicOSContacts.saveContact(contact);
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() => _ownerContacts[key] = contact);
    }
  }

  Contact? _ownerOf(_SspInfo ssp) =>
      _ownerContacts[ssp.owner.eip55With0x.toLowerCase()];

  Future<_SspInfo?> _fetchSsp(String slug) async {
    try {
      final data = await PublicOSBsp.socialServerRegistryMemoryContract
          .getSocialServerBySlug((slug: slug));
      if (data == null) return null;
      final exists = data[0] as bool;
      if (!exists) return null;

      // V4 gate status — best-effort. Failure shouldn't block SSP rendering.
      BigInt? subs;
      BigInt? threshold;
      bool? paid;
      try {
        final gate = await PublicOSTreasury.getSspGateStatus(slug);
        subs = gate.count;
        threshold = gate.threshold;
        paid = gate.paid;
      } catch (_) {}

      return _SspInfo(
        slug: data[1] as String,
        title: data[2] as String,
        apiUrl: data[3] as String,
        region: data[4] as String,
        owner: data[5] as EthereumAddress,
        subscriberCount: subs,
        gateThreshold: threshold,
        gatePaid: paid,
      );
    } catch (_) {
      return null;
    }
  }

  // ── Actions ─────────────────────────────────────────────────────────────

  /// True if this URL is the active feed server endpoint the client is using.
  bool _isUrlActive(String url) =>
      url.isNotEmpty && _activeSspUrl == url;

  Future<void> _connectTo(String url, String source, String label) async {
    final l10n = context.l10n;
    if (url.isEmpty) {
      _snack(l10n.sspScreenEndpointNoUrl);
      return;
    }
    _snack(l10n.sspScreenConnectingTo(label));
    // switchToFeedServer just persists the selection; there's no inline
    // reachability test like BSP's switchToRpcEndpoint. We reload, which
    // re-runs _loadServerStatus → checkServerHealth against the new active
    // URL, and the card will either render as active+reachable or the
    // header will drop back to grey.
    await PublicOSSsp.switchToFeedServer(url, source);
    if (!mounted) return;
    _snack(l10n.sspScreenConnectedTo(label));
    await _loadData();
  }

  Future<void> _deleteCustomServer(FeedServerEntry entry) async {
    final l10n = context.l10n;
    final id = entry.feedServerId;
    if (id == null) return;
    final ok = await PublicOSSsp.removeFeedServer(id);
    if (!mounted) return;
    if (ok) {
      _snack(l10n.sspScreenRemoved(entry.label));
      await _loadData();
    } else {
      _snack(l10n.sspScreenCouldNotRemove(entry.label));
    }
  }

  Future<void> _showRegisterSspSheet() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _RegisterSspSheet(),
    );
    if (result == true && mounted) await _loadData();
  }

  Future<void> _showAddCustomServerSheet() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _AddCustomServerSheet(),
    );
    if (result == true && mounted) await _loadData();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Opens the canonical Manage Server page against either a specific
  /// server (when [overrideUrl] is provided) or — when omitted — whichever
  /// feed server is currently active (subscribed SSP, custom server, or
  /// default). The same page works against any URL the user has signed-in
  /// authority for; the overrides exist so the per-row MANAGE actions in
  /// the Providers list can manage non-active servers too.
  Future<void> _openManageServer({
    String? overrideUrl,
    String? overrideLabel,
    bool? overrideIsSSP,
    String? overrideSspSlug,
  }) async {
    String? url = overrideUrl ??
        (_activeSspUrl.isNotEmpty
            ? _activeSspUrl
            : await PublicOSSsp.getActiveFeedServerUrl());
    if (url == null || url.isEmpty || !mounted) return;

    final isSSP = overrideIsSSP ??
        (_subscribedSsp != null && url == _subscribedSsp!.apiUrl);
    final label = overrideLabel ??
        (isSSP
            ? (_subscribedSsp!.title.isNotEmpty
                ? _subscribedSsp!.title
                : _subscribedSsp!.slug)
            : url);
    final slug = overrideSspSlug ??
        (isSSP && _subscribedSsp != null ? _subscribedSsp!.slug : null);

    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => ManageServerPage(
          serverUrl: url!,
          serverLabel: label,
          isSSP: isSSP,
          sspSlug: slug,
        ),
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return SystemAppScaffold(
      title: 'SSP',
      icon: Icons.cloud_outlined,
      pinHeader: true,
      builder: (context, scrollController, tokens) {
        return Stack(
          children: [
            if (!_loading)
              RefreshIndicator(
                onRefresh: () => _loadData(silent: true),
                color: tokens.starkWhite,
                backgroundColor: tokens.surfaceElevated,
                edgeOffset:
                    MediaQuery.of(context).padding.top + kToolbarHeight,
                child: _buildLoaded(scrollController, tokens),
              ),
            if (_loading)
              const Positioned(
                right: 16,
                bottom: 16,
                child: SafeArea(
                  child: PhigitalLoadingWidget(size: 28, showShadows: false),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildLoaded(ScrollController c, GlassTokens tokens) {
    return ListView(
      controller: c,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      children: [
        SizedBox(height: kToolbarHeight + 60),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
          child: _buildConnectionSection(tokens),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
          child: _buildProvidersSection(tokens),
        ),
        if (_isCitizen)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: _buildOperatorSection(tokens),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            child: _errorBanner(_error!),
          ),
      ],
    );
  }

  // ── Sections ────────────────────────────────────────────────────────────

  Widget _buildConnectionSection(GlassTokens tokens) {
    final color = _serverColor(tokens);
    final status = _serverStatus();
    return _group(
      tokens,
      id: 'connection',
      icon: Icons.cloud_outlined,
      title: context.l10n.sspScreenConnection,
      trailing: _pillBadge(tokens, status.label, color),
      children: [
        Text(
          status.description,
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            fontSize: 12,
            color: tokens.textDim,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 14),
        _kvRow(tokens, context.l10n.sspScreenEndpoint,
            _activeSspUrl.isEmpty ? '—' : _activeSspUrl),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: _legend(tokens)),
            const SizedBox(width: 10),
            _CardActionButton(
              label: context.l10n.sspScreenManage,
              icon: Icons.dns_rounded,
              onTap: _activeSspUrl.isNotEmpty
                  ? () => _openManageServer()
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildProvidersSection(GlassTokens tokens) {
    final list = _buildUnifiedList(tokens);
    return _group(
      tokens,
      id: 'providers',
      icon: Icons.dns_rounded,
      title: context.l10n.sspScreenProviders,
      children: [
        ...list,
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: SystemAppActionButton(
                label: context.l10n.sspScreenAddCustom,
                icon: Icons.storage_rounded,
                onTap: _showAddCustomServerSheet,
              ),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _buildUnifiedList(GlassTokens tokens) {
    final subscribedSlug = _subscribedSsp?.slug;
    final subscribedIsMine = subscribedSlug != null &&
        _mySsps.any((s) => s.slug == subscribedSlug);

    final widgets = <Widget>[];

    Widget sspRow(_SspInfo ssp, {required bool isMine}) {
      final isSubscribed = ssp.slug == subscribedSlug;
      final badges = <String>[
        if (isMine) context.l10n.sspScreenBadgeMine,
        if (isSubscribed) context.l10n.sspScreenBadgeSubscribed,
      ];
      final label = ssp.title.isNotEmpty ? ssp.title : ssp.slug;
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _SspCard(
          ssp: ssp,
          ownerContact: _ownerOf(ssp),
          badges: badges,
          isActive: _isUrlActive(ssp.apiUrl),
          onConnect: ssp.apiUrl.isEmpty
              ? null
              : () => _connectTo(ssp.apiUrl, 'ssp', label),
          onManage: ssp.apiUrl.isEmpty
              ? null
              : () => _openManageServer(
                    overrideUrl: ssp.apiUrl,
                    overrideLabel: label,
                    overrideIsSSP: true,
                    overrideSspSlug: ssp.slug,
                  ),
        ),
      );
    }

    // 1. Mine (owned SSPs)
    for (final ssp in _mySsps) {
      widgets.add(sspRow(ssp, isMine: true));
    }

    // 2. Subscribed (only if not already listed under mine)
    if (_subscribedSsp != null && !subscribedIsMine) {
      widgets.add(sspRow(_subscribedSsp!, isMine: false));
    }

    // 3. Customs (server endpoints — not chain SSPs)
    for (final custom in _customServers) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _CustomServerCard(
            entry: custom,
            isActive: _isUrlActive(custom.url),
            onConnect: () => _connectTo(custom.url, 'custom', custom.label),
            onManage: () => _openManageServer(
              overrideUrl: custom.url,
              overrideLabel: custom.label,
              overrideIsSSP: false,
            ),
            onDelete: () => _deleteCustomServer(custom),
          ),
        ),
      );
    }

    if (widgets.isEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text(
              _isCitizen
                  ? context.l10n.sspScreenEmptyCitizen
                  : context.l10n.sspScreenEmptyPrivate,
              style: TextStyle(
                color: tokens.textDim,
                fontSize: 12,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return widgets;
  }

  Color _serverColor(GlassTokens tokens) {
    if (!_sspReachable) return tokens.textDim;
    if (_sspSource == 'ssp' ||
        _sspSource == 'custom' ||
        _sspSource == 'override') {
      return tokens.connectedAccent;
    }
    return Colors.orangeAccent;
  }

  ({String label, String description}) _serverStatus() {
    final l10n = context.l10n;
    if (!_sspReachable) {
      return (
        label: l10n.sspScreenStatusUnreachableLabel,
        description: l10n.sspScreenStatusUnreachableDesc,
      );
    }
    switch (_sspSource) {
      case 'ssp':
        return (
          label: l10n.sspScreenStatusSspLabel,
          description: l10n.sspScreenStatusSspDesc,
        );
      case 'custom':
        return (
          label: l10n.sspScreenStatusCustomLabel,
          description: l10n.sspScreenStatusCustomDesc,
        );
      case 'override':
        return (
          label: l10n.sspScreenStatusOverrideLabel,
          description: l10n.sspScreenStatusOverrideDesc,
        );
      default:
        return (
          label: l10n.sspScreenStatusPublicLabel,
          description: l10n.sspScreenStatusPublicDesc,
        );
    }
  }

  Widget _legend(GlassTokens tokens) {
    final items = <(Color, String)>[
      (tokens.textDim, context.l10n.sspScreenLegendNoServer),
      (Colors.orangeAccent, context.l10n.sspScreenLegendPublicFallback),
      (tokens.connectedAccent, context.l10n.sspScreenLegendSspOrCustom),
    ];
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tokens.glassFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.borderSubtle),
      ),
      child: Column(
        children: items
            .map(
              (item) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: item.$1,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      item.$2,
                      style: TextStyle(
                        fontFamily: 'SpaceGrotesk',
                        fontSize: 11,
                        color: tokens.textDim,
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  /// The operator agreement: SIGNED or NOT SIGNED, then
  /// SIGN AGREEMENT or REGISTER. Every registration door requires the current
  /// operator agreement, so REGISTER only shows once it is signed. Citizens
  /// only: the registries' session modifier refuses privates anyway.
  Widget _buildOperatorSection(GlassTokens tokens) {
    final signed = _operatorSigned == true;
    // Only a definite "not listed" hides REGISTER; unknown keeps it (the tx decides).
    final invited = _registrationAllowed != false;
    return _group(
      tokens,
      id: 'operator',
      icon: Icons.handshake_rounded,
      title: context.l10n.operatorAgreementSection,
      trailing: _pillBadge(
        tokens,
        signed
            ? context.l10n.operatorAgreementSignedPill
            : context.l10n.operatorAgreementUnsignedPill,
        signed ? tokens.connectedAccent : tokens.fallbackAccent,
      ),
      children: [
        Text(
          !signed
              ? context.l10n.operatorAgreementUnsignedBody
              : invited
                  ? context.l10n.operatorAgreementSignedBody
                  : context.l10n.providerRegistrationInviteOnly,
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            fontSize: 12,
            color: tokens.textDim,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 14),
        if (signed && invited)
          SystemAppActionButton(
            label: context.l10n.sspScreenRegisterSsp,
            icon: Icons.add_circle_outline,
            onTap: _showRegisterSspSheet,
          ),
        if (!signed)
          SystemAppActionButton(
            label: context.l10n.operatorAgreementSign,
            icon: Icons.draw_rounded,
            onTap: () async {
              final ok = await showOperatorAgreementSheet(context);
              if (ok && mounted) _loadData(silent: true);
            },
          ),
      ],
    );
  }

  Future<bool?> _readOperatorSigned(EthereumAddress addr) async {
    try {
      return await PublicOSAgreements.hasAgreed(
          PublicOSAgreements.kindOperator, addr);
    } catch (_) {
      return null;
    }
  }

  /// Collapsible settings group.
  /// Borrows `channel_settings_page`'s accordion drawers: one group open at a
  /// time, the whole header row toggles, the chevron turns 90°, the first group
  /// starts open. Shell deltas: no divider line (borderless), and the header's
  /// glyphs brighten on hover or while open, the way a rail row does.
  Widget _group(
    GlassTokens tokens, {
    required String id,
    required IconData icon,
    required String title,
    Widget? trailing,
    VoidCallback? onHeaderTap,
    required List<Widget> children,
  }) {
    final open = _openGroup == id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GroupHeader(
          icon: icon,
          title: title,
          trailing: trailing,
          open: open,
          onTap: () {
            setState(() => _openGroup = open ? null : id);
            onHeaderTap?.call();
          },
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: open
              ? Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: children,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  // ── Section helpers ─────────────────────────────────────────────────────

  Widget _sectionHeader(
    GlassTokens tokens,
    IconData icon,
    String title, {
    Widget? trailing,
  }) {
    return Row(
      children: [
        Icon(icon, color: tokens.connectedAccent, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              color: tokens.starkWhite,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
        ),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _pillBadge(GlassTokens tokens, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'SpaceGrotesk',
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.5,
          color: color,
        ),
      ),
    );
  }

  Widget _kvRow(GlassTokens tokens, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: tokens.textDim,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: tokens.starkWhite,
            ),
          ),
        ),
      ],
    );
  }

  Widget _errorBanner(String text) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11, color: Colors.redAccent),
      ),
    );
  }
}

class _SspCard extends StatelessWidget {
  final _SspInfo ssp;
  final List<String> badges;
  final VoidCallback? onConnect;
  final VoidCallback? onManage;
  final bool isActive;
  final Contact? ownerContact;

  const _SspCard({
    required this.ssp,
    this.badges = const [],
    this.onConnect,
    this.onManage,
    this.isActive = false,
    this.ownerContact,
  });

  String _truncateAddress(String addr) {
    if (addr.length <= 12) return addr;
    return '${addr.substring(0, 6)}...${addr.substring(addr.length - 4)}';
  }

  String _truncateUrl(String url) {
    if (url.length <= 38) return url;
    return '${url.substring(0, 35)}...';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final hasActions = onConnect != null || onManage != null;
    final borderColor = isActive
        ? tokens.connectedAccent.withValues(alpha: 0.55)
        : tokens.borderSubtle;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: null,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: borderColor,
              width: isActive ? 1.4 : 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (isActive) ...[
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: tokens.connectedAccent,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Flexible(
                              child: Text(
                                ssp.title.isNotEmpty ? ssp.title : ssp.slug,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: tokens.starkWhite,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${ssp.slug}${ssp.region.isNotEmpty ? '  ·  ${ssp.region}' : ''}',
                          style: TextStyle(
                            fontSize: 11,
                            color: tokens.textDim,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (badges.isNotEmpty)
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: badges.map((l) => _badge(tokens, l)).toList(),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _kvRow(tokens, context.l10n.sspScreenLabelUrl,
                  _truncateUrl(ssp.apiUrl.isEmpty ? '—' : ssp.apiUrl)),
              const SizedBox(height: 8),
              _runByRow(context, tokens),
              if (_subsLine(context, ssp) != null) ...[
                const SizedBox(height: 8),
                _kvRow(tokens, context.l10n.sspScreenLabelSubs,
                    _subsLine(context, ssp)!),
              ],
              if (hasActions) ...[
                const SizedBox(height: 12),
                _actionRow(context),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge(GlassTokens tokens, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tokens.starkWhite.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: tokens.starkWhite.withValues(alpha: 0.3),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
          color: tokens.starkWhite,
        ),
      ),
    );
  }

  Widget _actionRow(BuildContext context) {
    return Row(
      children: [
        if (onConnect != null)
          _CardActionButton(
            label: isActive
                ? context.l10n.sspScreenConnected
                : context.l10n.sspScreenConnect,
            icon: Icons.link,
            onTap: isActive ? null : onConnect,
          ),
        if (onConnect != null && onManage != null)
          const SizedBox(width: 8),
        if (onManage != null)
          _CardActionButton(
            label: context.l10n.sspScreenManage,
            icon: Icons.dns_rounded,
            onTap: onManage,
          ),
      ],
    );
  }

  Widget _runByRow(BuildContext context, GlassTokens tokens) {
    final name = ownerContact?.publicosDisplayName ??
        ownerContact?.displayName ??
        _truncateAddress(ssp.owner.eip55With0x);
    return Row(
      children: [
        SizedBox(
          width: 50,
          child: Text(
            context.l10n.sspScreenRunBy,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: tokens.textDim,
            ),
          ),
        ),
        GlassContactIcon(
          opensProfile: true,
          contact: ownerContact,
          address: ssp.owner.eip55With0x,
          size: 20,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: ContactProfileTap(contact: ownerContact, address: ssp.owner.eip55With0x, child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: tokens.starkWhite,
              letterSpacing: 0.3,
            ),
          )),
        ),
      ],
    );
  }

  Widget _kvRow(GlassTokens tokens, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 50,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: tokens.textDim,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 11,
              color: tokens.starkWhite,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ],
    );
  }

  /// One-line subscriber summary. Mirrors `_BspCard._subsLine` — subscriber
  /// count only, with no min-subscriber gate framing.
  static String? _subsLine(BuildContext context, _SspInfo ssp) {
    final count = ssp.subscriberCount;
    if (count == null) return null;
    final n = count.toInt();
    return context.l10n.sspScreenSubscriberCount(n);
  }
}

class _CustomServerCard extends StatelessWidget {
  final FeedServerEntry entry;
  final bool isActive;
  final VoidCallback? onConnect;
  final VoidCallback? onManage;
  final VoidCallback? onDelete;

  const _CustomServerCard({
    required this.entry,
    required this.isActive,
    this.onConnect,
    this.onManage,
    this.onDelete,
  });

  String _truncateUrl(String url) {
    if (url.length <= 38) return url;
    return '${url.substring(0, 35)}...';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final borderColor = isActive
        ? tokens.connectedAccent.withValues(alpha: 0.55)
        : tokens.borderSubtle;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: borderColor,
          width: isActive ? 1.4 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (isActive) ...[
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: tokens.connectedAccent,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Text(
                            entry.label,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: tokens.starkWhite,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.l10n.sspScreenCustomServerSubtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: tokens.textDim,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 50,
                child: Text(
                  context.l10n.sspScreenLabelUrl,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    color: tokens.textDim,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  _truncateUrl(entry.url),
                  style: TextStyle(
                    fontSize: 11,
                    color: tokens.starkWhite,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (onConnect != null)
                _CardActionButton(
                  label: isActive
              ? context.l10n.sspScreenConnected
              : context.l10n.sspScreenConnect,
                  icon: Icons.link,
                  onTap: isActive ? null : onConnect,
                ),
              if (onConnect != null && onManage != null)
                const SizedBox(width: 8),
              if (onManage != null)
                _CardActionButton(
                  label: context.l10n.sspScreenManage,
                  icon: Icons.dns_rounded,
                  onTap: onManage,
                ),
              if ((onConnect != null || onManage != null) && onDelete != null)
                const SizedBox(width: 8),
              if (onDelete != null)
                _CardActionButton(
                  label: context.l10n.sspScreenDelete,
                  icon: Icons.delete_outline,
                  onTap: onDelete,
                  destructive: true,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CardActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool destructive;

  const _CardActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final Color fg = onTap == null
        ? tokens.textDim
        : destructive
            ? Colors.redAccent
            : tokens.starkWhite;
    final Color border = onTap == null
        ? tokens.borderSubtle
        : destructive
            ? Colors.redAccent.withValues(alpha: 0.4)
            : tokens.borderMedium;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: onTap == null ? 0.02 : 0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Sheets ─────────────────────────────────────────────────────────────────

class _SheetShell extends StatelessWidget {
  final Widget child;

  const _SheetShell({required this.child});

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          padding: EdgeInsets.fromLTRB(
            24,
            20,
            24,
            24 + MediaQuery.of(context).viewInsets.bottom,
          ),
          decoration: BoxDecoration(
            color: tokens.surfaceDeep.withValues(alpha: 0.92),
            border: Border(
              top: BorderSide(
                color: tokens.starkWhite.withValues(alpha: 0.15),
              ),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}



// ── Shared sheet helpers ───────────────────────────────────────────────────

Widget _sheetButton(
  BuildContext context, {
  required String label,
  required bool filled,
  required VoidCallback? onTap,
  bool chainAction = false,
}) {
  final tokens = GlassTokens.of(context);
  final labelText = Text(
    label,
    style: const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w800,
      letterSpacing: 2,
    ),
  );

  final child = chainAction
      ? Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const _ChainActionBadge(),
            const SizedBox(width: 10),
            labelText,
          ],
        )
      : labelText;

  return ElevatedButton(
    style: ElevatedButton.styleFrom(
      backgroundColor: filled
          ? tokens.starkWhite
          : Colors.white.withValues(alpha: 0.06),
      foregroundColor:
          filled ? tokens.background : tokens.starkWhite,
      disabledBackgroundColor: Colors.white.withValues(alpha: 0.03),
      disabledForegroundColor: tokens.textDim,
      padding: const EdgeInsets.symmetric(vertical: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: filled
              ? Colors.transparent
              : tokens.borderMedium,
        ),
      ),
    ),
    onPressed: onTap,
    child: child,
  );
}

class _RegisterSspSheet extends StatefulWidget {
  const _RegisterSspSheet();

  @override
  State<_RegisterSspSheet> createState() => _RegisterSspSheetState();
}

class _RegisterSspSheetState extends State<_RegisterSspSheet> {
  GlassTokens get tokens => GlassTokens.of(context);

  final _formKey = GlobalKey<FormState>();
  final _slug = TextEditingController();
  final _title = TextEditingController();
  final _apiUrl = TextEditingController();
  final _region = TextEditingController();
  final _website = TextEditingController();

  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _slug.dispose();
    _title.dispose();
    _apiUrl.dispose();
    _region.dispose();
    _website.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!_formKey.currentState!.validate()) return;
    final creds = PublicOS.currentBlockchainPrivateKey;
    if (creds == null) {
      setState(() => _error = context.l10n.sspScreenNoActiveSession);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final slug = _slug.text.trim();
      final title = _title.text.trim();
      final apiUrl = _apiUrl.text.trim();
      final region = _region.text.trim();
      final website = _website.text.trim();

      final pointerTypes = <String>[];
      final pointerValues = <String>[];
      if (website.isNotEmpty) {
        pointerTypes.add('website');
        pointerValues.add(website);
      }

      final txHash = await PublicOSBsp.socialServerRegistryManagerContract
          .registerSocialServerWithPointers(
        (
          slug: slug,
          title: title,
          apiUrl: apiUrl,
          region: region,
          pointerTypes: pointerTypes,
          pointerValues: pointerValues,
        ),
        credentials: creds,
      );

      final ok = await TxUtils.waitForReceipt(txHash, label: 'registerSSP');
      if (!ok) {
        throw Exception('Registration reverted on-chain');
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = localizedError(context.l10n, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    return _SheetShell(
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.sspScreenRegisterSsp,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                  color: tokens.textDim,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.sspScreenRegisterTitle,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: tokens.starkWhite,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                context.l10n.sspScreenRegisterSubtitle,
                style: TextStyle(fontSize: 12, color: tokens.textDim),
              ),
              const SizedBox(height: 22),
              _SheetField(
                controller: _slug,
                label: context.l10n.sspScreenFieldSlug,
                hint: context.l10n.sspScreenSlugHint,
                helper: context.l10n.sspScreenSlugHelper,
                enabled: !_submitting,
                onChanged: (v) {
                  final lower = v.toLowerCase();
                  if (lower != v) {
                    _slug.value = _slug.value.copyWith(
                      text: lower,
                      selection:
                          TextSelection.collapsed(offset: lower.length),
                    );
                  }
                },
                validator: (value) {
                  final s = value?.trim() ?? '';
                  if (s.isEmpty) return context.l10n.sspScreenSlugRequired;
                  if (!RegExp(r'^[a-z0-9][a-z0-9_-]{2,31}$').hasMatch(s)) {
                    return context.l10n.sspScreenSlugInvalid;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),
              _SheetField(
                controller: _title,
                label: context.l10n.sspScreenFieldTitle,
                hint: context.l10n.sspScreenTitleHint,
                enabled: !_submitting,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? context.l10n.sspScreenTitleRequired
                    : null,
              ),
              const SizedBox(height: 14),
              _SheetField(
                controller: _apiUrl,
                label: context.l10n.sspScreenFieldApiUrl,
                hint: 'https://feeds.example.com',
                enabled: !_submitting,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? context.l10n.sspScreenApiUrlRequired
                    : null,
              ),
              const SizedBox(height: 14),
              _SheetField(
                controller: _region,
                label: context.l10n.sspScreenFieldRegion,
                hint: context.l10n.sspScreenRegionHint,
                enabled: !_submitting,
              ),
              const SizedBox(height: 14),
              _SheetField(
                controller: _website,
                label: context.l10n.sspScreenFieldWebsite,
                hint: 'https://example.com',
                enabled: !_submitting,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.redAccent,
                  ),
                ),
              ],
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: _sheetButton(
                      context,
                      label: context.l10n.actionCancel,
                      filled: false,
                      onTap: _submitting
                          ? null
                          : () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: _sheetButton(
                      context,
                      label: _submitting
                          ? context.l10n.sspScreenRegistering
                          : context.l10n.sspScreenRegister,
                      filled: true,
                      chainAction: true,
                      onTap: _submitting ? null : _submit,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddCustomServerSheet extends StatefulWidget {
  const _AddCustomServerSheet();

  @override
  State<_AddCustomServerSheet> createState() => _AddCustomServerSheetState();
}

class _AddCustomServerSheetState extends State<_AddCustomServerSheet> {
  GlassTokens get tokens => GlassTokens.of(context);

  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _url = TextEditingController();

  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final url = _url.text.trim();
      final nameText = _name.text.trim();
      final result = await PublicOSSsp.addFeedServer(
        url,
        name: nameText.isNotEmpty ? nameText : null,
      );
      if (result == null) {
        throw Exception('Could not save this server');
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = localizedError(context.l10n, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    return _SheetShell(
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.sspScreenAddCustom,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
                color: tokens.textDim,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.sspScreenAddCustomTitle,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: tokens.starkWhite,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.sspScreenAddCustomSubtitle,
              style: TextStyle(fontSize: 12, color: tokens.textDim),
            ),
            const SizedBox(height: 22),
            _SheetField(
              controller: _name,
              label: context.l10n.sspScreenFieldName,
              hint: context.l10n.sspScreenNameHint,
              enabled: !_submitting,
            ),
            const SizedBox(height: 14),
            _SheetField(
              controller: _url,
              label: context.l10n.sspScreenFieldServerUrl,
              hint: 'https://...',
              enabled: !_submitting,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? context.l10n.sspScreenUrlRequired
                  : null,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.redAccent,
                ),
              ),
            ],
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: _sheetButton(
                    context,
                    label: context.l10n.actionCancel,
                    filled: false,
                    onTap: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: _sheetButton(
                    context,
                    label: _submitting
                        ? context.l10n.sspScreenTesting
                        : context.l10n.sspScreenAdd,
                    filled: true,
                    onTap: _submitting ? null : _submit,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final String? helper;
  final bool enabled;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;

  _SheetField({
    required this.controller,
    required this.label,
    required this.hint,
    this.helper,
    this.enabled = true,
    this.validator,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: tokens.borderMedium),
    );
    return TextFormField(
      controller: controller,
      enabled: enabled,
      validator: validator,
      onChanged: onChanged,
      style: TextStyle(
        fontSize: 13,
        color: tokens.starkWhite,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperStyle:
            TextStyle(fontSize: 10, color: tokens.textDim),
        labelStyle:
            TextStyle(fontSize: 12, color: tokens.textDim),
        hintStyle: TextStyle(
          fontSize: 13,
          color: tokens.textDim.withValues(alpha: 0.6),
        ),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.04),
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: tokens.connectedAccent.withValues(alpha: 0.5),
            width: 1.5,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: Colors.redAccent.withValues(alpha: 0.6),
          ),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );
  }
}

/// Universal "this triggers an on-chain transaction" badge. Same link icon
/// used by the BSP screen header, rendered as a small glass square so it
/// reads as a peer of the BSP visual language across the app.
class _ChainActionBadge extends StatelessWidget {
  const _ChainActionBadge();

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final filled =
        DefaultTextStyle.of(context).style.color == tokens.background;
    final iconColor = filled ? tokens.background : tokens.starkWhite;
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        color: iconColor.withValues(alpha: filled ? 0.12 : 0.1),
        border: Border.all(color: iconColor.withValues(alpha: 0.4)),
      ),
      child: Icon(Icons.link, size: 11, color: iconColor),
    );
  }
}

class _GroupHeader extends StatefulWidget {
  final IconData icon;
  final String title;
  final Widget? trailing;
  final bool open;
  final VoidCallback onTap;

  const _GroupHeader({
    required this.icon,
    required this.title,
    required this.trailing,
    required this.open,
    required this.onTap,
  });

  @override
  State<_GroupHeader> createState() => _GroupHeaderState();
}

class _GroupHeaderState extends State<_GroupHeader> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final fg = (_hovered || widget.open) ? tokens.starkWhite : tokens.textDim;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        // Open = a really light `glassFill` wash, so it stands out; a
        // hovered closed header gets half of that, so hover
        // never reads as open. The 14 px inset matches the tiles below, so the
        // wash's edge lines up with theirs and the glyph lines up with their
        // text.
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: widget.open
                ? tokens.glassFill
                : _hovered
                    ? tokens.glassFill.withValues(alpha: tokens.glassFill.a / 2)
                    : tokens.glassFill.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(widget.icon, color: fg, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.title,
                  style: TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    color: tokens.starkWhite,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              if (widget.trailing != null) ...[
                widget.trailing!,
                const SizedBox(width: 10),
              ],
              AnimatedRotation(
                turns: widget.open ? 0.25 : 0,
                duration: const Duration(milliseconds: 180),
                child: Icon(Icons.chevron_right_rounded, size: 18, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
