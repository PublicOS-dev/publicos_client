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
import 'package:publicos_client/pages/treasury_page.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';

/// BSP page is now a status + connection surface only. Subscription, switch
/// and rent flows live exclusively in Treasury's Network Access card. Here
/// the user sees their currently subscribed BSP (if any), connects to it
/// or to a custom RPC, registers a new BSP, or adds a custom RPC endpoint.

class BspScreen extends StatefulWidget {
  const BspScreen({super.key});

  @override
  State<BspScreen> createState() => _BspScreenState();
}

class _BspInfo {
  final String slug;
  final String title;
  final String apiUrl;
  final String region;
  final EthereumAddress owner;

  /// V4 gate data — current subscriber count, the min-subscriber threshold,
  /// and whether the slug currently accrues provider payments
  /// (subscriberCount >= threshold). `null` fields mean the gate read failed
  /// or hasn't happened yet — treat as unknown and hide the gate indicator.
  final BigInt? subscriberCount;
  final BigInt? gateThreshold;
  final bool? gatePaid;

  const _BspInfo({
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

class _BspScreenState extends State<BspScreen> {
  bool _loading = true;
  String? _error;

  // Chain connection status (read sync from PublicOS, refined async).
  String _activeRpcUrl = '';
  String _rpcSource = 'public';
  bool _chainReachable = false;
  int? _blockNumber;

  bool _isCitizen = false;
  // Operator agreement: null = not read (or not a citizen).
  bool? _operatorSigned;
  // Registration allowlist: false = the BSP
  // registry is invite-only and this account is not listed; null = unknown.
  bool? _registrationAllowed;
  // One section open at a time, the Services / Account / Settings accordion.
  String? _openGroup = 'connection';

  // Citizen status
  _BspInfo? _subscribedBsp;

  // Private status — the BSP service-sub expiry (independent of the domain).
  BigInt? _bspPaidUntil;
  BigInt? _tokenBalance;

  // Lists — only the user's owned BSPs (for "MINE" badge + earnings footer
  // hint) and custom RPCs are shown. The chain directory of every other BSP
  // moved to Treasury's picker sheet.
  List<_BspInfo> _myBsps = const [];
  List<RpcEndpointEntry> _customRpcs = const [];

  // Resolved owner contacts, keyed by lowercased eip55 address. Loaded
  // asynchronously after the BSP lists; nulls mean we tried and got nothing.
  final Map<String, Contact?> _ownerContacts = {};

  @override
  void initState() {
    super.initState();
    _activeRpcUrl = PublicOS.activeRpcUrl;
    _rpcSource = PublicOS.activeRpcSource;
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
            _error = context.l10n.bspScreenNoActiveAccount;
          });
        }
        return;
      }
      final addr = EthereumAddress.fromHex(addrStr);

      await _loadChainStatus();

      _isCitizen = await _safeIsCitizen(addr);
      _operatorSigned = _isCitizen ? await _readOperatorSigned(addr) : null;
      _registrationAllowed = _isCitizen ? await PublicOSBsp.canRegisterBsp(addr) : null;
      await _loadSubscription(addr);
      if (!_isCitizen) {
        await _loadRent(addr);
        await _loadTokenBalance(addr);
      }
      await _loadMyBsps(addr);
      await _loadCustomRpcs();

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

  Future<void> _loadChainStatus() async {
    try {
      _blockNumber = await PublicOSBsp.getBlockNumber();
      _chainReachable = true;
    } catch (_) {
      _chainReachable = false;
      _blockNumber = null;
    }
    // Refresh in case session restore changed the active endpoint.
    _activeRpcUrl = PublicOS.activeRpcUrl;
    _rpcSource = PublicOS.activeRpcSource;
  }

  Future<bool> _safeIsCitizen(EthereumAddress addr) async {
    try {
      return await PublicOSAccounts.isCitizen(addr);
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadSubscription(EthereumAddress addr) async {
    try {
      // subs_v2: the assigned BSP slug lives on the one SubsMemory (axis 0).
      final slug = await PublicOSTreasury.assignedSlug(PublicOSTreasury.bspAxis, addr);
      if (slug.isNotEmpty) {
        _subscribedBsp = await _fetchBsp(slug);
      }
    } catch (_) {}
  }

  Future<void> _loadRent(EthereumAddress addr) async {
    try {
      // subs_v2: ONE clock for both services — when the balance (or dormancy)
      // runs out. The BSP card shows it beside the BSP it pays for.
      _bspPaidUntil = await PublicOSTreasury.coveredUntil(addr);
    } catch (_) {}
  }

  Future<void> _loadTokenBalance(EthereumAddress addr) async {
    try {
      final mainHex = await PublicOSSafe.getMainSafeAddress(addr);
      if (mainHex == null) return;
      _tokenBalance = await PublicOSTreasury.getTokenBalance(
        EthereumAddress.fromHex(mainHex),
      );
    } catch (_) {}
  }

  Future<void> _loadMyBsps(EthereumAddress addr) async {
    try {
      final mem = PublicOSBsp.bspRegistryMemoryContract;
      final slugs = await mem.getBSPsByOwner((owner: addr));
      final list = <_BspInfo>[];
      for (final slug in slugs) {
        final info = await _fetchBsp(slug);
        if (info != null) list.add(info);
      }
      _myBsps = list;
    } catch (_) {}
  }

  Future<void> _loadCustomRpcs() async {
    try {
      final all = await PublicOSBsp.buildRpcEndpointList();
      _customRpcs = all.where((e) => e.source == 'custom').toList();
    } catch (_) {
      _customRpcs = const [];
    }
  }

  Future<void> _loadOwnerContacts() async {
    final owners = <EthereumAddress>{
      ..._myBsps.map((b) => b.owner),
      if (_subscribedBsp != null) _subscribedBsp!.owner,
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

  Contact? _ownerOf(_BspInfo bsp) =>
      _ownerContacts[bsp.owner.eip55With0x.toLowerCase()];

  Future<_BspInfo?> _fetchBsp(String slug) async {
    try {
      final data = await PublicOSBsp.bspRegistryMemoryContract
          .getBSPBySlug((slug: slug));
      if (data == null) return null;
      final exists = data[0] as bool;
      if (!exists) return null;

      // V4 gate status — best-effort. Failure shouldn't block BSP rendering
      // (the registry data is the load-bearing part); just leave the gate
      // fields null.
      BigInt? subs;
      BigInt? threshold;
      bool? paid;
      try {
        final gate = await PublicOSTreasury.getBspGateStatus(slug);
        subs = gate.count;
        threshold = gate.threshold;
        paid = gate.paid;
      } catch (_) {}

      return _BspInfo(
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

  String _formatTimestamp(BigInt? ts) {
    if (ts == null || ts == BigInt.zero) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ts.toInt() * 1000);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  // ── Actions ─────────────────────────────────────────────────────────────

  /// True if this URL is the active RPC endpoint the client is talking to.
  bool _isRpcActive(String url) =>
      url.isNotEmpty && PublicOS.activeRpcUrl == url;

  Future<void> _connectTo(String url, String source, String label) async {
    final l10n = context.l10n;
    if (url.isEmpty) {
      _snack(l10n.bspScreenEndpointNoUrl);
      return;
    }
    _snack(l10n.bspScreenConnectingTo(label));
    final ok = await PublicOSBsp.switchToRpcEndpoint(url, source);
    if (!mounted) return;
    if (ok) {
      _snack(l10n.bspScreenConnectedTo(label));
      await _loadData();
    } else {
      _snack(l10n.bspScreenUnreachable(label));
    }
  }

  Future<void> _deleteCustomRpc(RpcEndpointEntry entry) async {
    final l10n = context.l10n;
    final id = entry.rpcServerId;
    if (id == null) return;
    final ok = await PublicOSBsp.removeRpcServer(id);
    if (!mounted) return;
    if (ok) {
      _snack(l10n.bspScreenRemoved(entry.label));
      await _loadData();
    } else {
      _snack(l10n.bspScreenCouldNotRemove(entry.label));
    }
  }

  Future<void> _showRegisterBspSheet() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _RegisterBspSheet(),
    );
    if (result == true && mounted) await _loadData();
  }

  Future<void> _showAddCustomRpcSheet() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _AddCustomRpcSheet(),
    );
    if (result == true && mounted) await _loadData();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openTreasury() {
    Navigator.of(context).push(
      CupertinoPageRoute(builder: (_) => const TreasuryPage()),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return SystemAppScaffold(
      title: 'BSP',
      icon: Icons.link,
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
          child: _buildSubscriptionSection(tokens),
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
    final color = _chainColor(tokens);
    final status = _chainStatus();
    return _group(
      tokens,
      id: 'connection',
      icon: Icons.link,
      title: context.l10n.bspScreenConnection,
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
        _kvRow(tokens, context.l10n.bspScreenEndpoint,
            _activeRpcUrl.isEmpty ? '—' : _activeRpcUrl),
        const SizedBox(height: 4),
        _kvRow(tokens, context.l10n.bspScreenBlock,
            _blockNumber != null ? '#$_blockNumber' : '—'),
        const SizedBox(height: 14),
        _legend(tokens),
      ],
    );
  }

  Widget _buildSubscriptionSection(GlassTokens tokens) {
    final hasSubscription = _subscribedBsp != null;
    final providerLabel = _subscribedBsp?.title.isNotEmpty == true
        ? _subscribedBsp!.title
        : (_subscribedBsp?.slug ?? context.l10n.bspScreenNone);
    final roleColor =
        _isCitizen ? tokens.connectedAccent : tokens.starkWhite;
    final roleLabel = _isCitizen
        ? context.l10n.bspScreenRoleCitizen
        : context.l10n.bspScreenRolePrivate;

    final rows = <Widget>[
      _kvRow(tokens, context.l10n.bspScreenProvider, providerLabel),
    ];
    if (hasSubscription && !_isCitizen) {
      rows.add(const SizedBox(height: 4));
      rows.add(_kvRow(
          tokens, context.l10n.bspScreenBalance, _formatPosWei(_tokenBalance)));
      rows.add(const SizedBox(height: 4));
      rows.add(_kvRow(tokens, context.l10n.bspScreenPaidUntil,
          _formatTimestamp(_bspPaidUntil)));
    } else if (!hasSubscription) {
      rows.add(const SizedBox(height: 4));
      rows.add(_kvRow(
        tokens,
        context.l10n.bspScreenTip,
        _isCitizen
            ? context.l10n.bspScreenTipCitizen
            : context.l10n.bspScreenTipPrivate,
      ));
    }

    return _group(
      tokens,
      id: 'subscription',
      icon: Icons.account_balance_rounded,
      title: context.l10n.bspScreenSubscription,
      trailing: _pillBadge(tokens, roleLabel, roleColor),
      children: [
        ...rows,
        const SizedBox(height: 14),
        SystemAppActionButton(
          label: context.l10n.bspScreenManageInTreasury,
          icon: Icons.account_balance_rounded,
          onTap: _openTreasury,
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
      title: context.l10n.bspScreenProviders,
      children: [
        ...list,
        if (_myBsps.isNotEmpty) ...[
          const SizedBox(height: 6),
          _earningsFooter(tokens),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: SystemAppActionButton(
                label: context.l10n.bspScreenAddCustomRpc,
                icon: Icons.storage_rounded,
                onTap: _showAddCustomRpcSheet,
              ),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _buildUnifiedList(GlassTokens tokens) {
    final subscribedSlug = _subscribedBsp?.slug;
    final subscribedIsMine = subscribedSlug != null &&
        _myBsps.any((b) => b.slug == subscribedSlug);

    final widgets = <Widget>[];

    Widget bspRow(_BspInfo bsp, {required bool isMine}) {
      final isSubscribed = bsp.slug == subscribedSlug;
      final badges = <String>[
        if (isMine) context.l10n.bspScreenBadgeMine,
        if (isSubscribed) context.l10n.bspScreenBadgeSubscribed,
      ];
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _BspCard(
          bsp: bsp,
          ownerContact: _ownerOf(bsp),
          badges: badges,
          isActive: _isRpcActive(bsp.apiUrl),
          onConnect: bsp.apiUrl.isEmpty
              ? null
              : () => _connectTo(
                    bsp.apiUrl,
                    'bsp',
                    bsp.title.isNotEmpty ? bsp.title : bsp.slug,
                  ),
        ),
      );
    }

    // 1. Mine (owned BSPs) — registry entries the user runs
    for (final bsp in _myBsps) {
      widgets.add(bspRow(bsp, isMine: true));
    }

    // 2. Subscribed (only if not already listed under mine)
    if (_subscribedBsp != null && !subscribedIsMine) {
      widgets.add(bspRow(_subscribedBsp!, isMine: false));
    }

    // 3. Customs (RPC endpoints — not chain BSPs)
    for (final custom in _customRpcs) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _CustomRpcCard(
            entry: custom,
            isActive: _isRpcActive(custom.url),
            onConnect: () => _connectTo(custom.url, 'custom', custom.label),
            onDelete: () => _deleteCustomRpc(custom),
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
                  ? context.l10n.bspScreenEmptyCitizen
                  : context.l10n.bspScreenEmptyPrivate,
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

  Color _chainColor(GlassTokens tokens) {
    if (!_chainReachable) return tokens.textDim;
    if (_rpcSource == 'bsp' || _rpcSource == 'custom') {
      return tokens.connectedAccent;
    }
    return Colors.orangeAccent;
  }

  ({String label, String description}) _chainStatus() {
    final l10n = context.l10n;
    if (!_chainReachable) {
      return (
        label: l10n.bspScreenStatusUnreachableLabel,
        description: l10n.bspScreenStatusUnreachableDesc,
      );
    }
    if (_rpcSource == 'bsp') {
      return (
        label: l10n.bspScreenStatusBspLabel,
        description: l10n.bspScreenStatusBspDesc,
      );
    }
    if (_rpcSource == 'custom') {
      return (
        label: l10n.bspScreenStatusCustomLabel,
        description: l10n.bspScreenStatusCustomDesc,
      );
    }
    return (
      label: l10n.bspScreenStatusPublicLabel,
      description: l10n.bspScreenStatusPublicDesc,
    );
  }

  Widget _legend(GlassTokens tokens) {
    final items = <(Color, String)>[
      (tokens.textDim, context.l10n.bspScreenLegendNoConnection),
      (Colors.orangeAccent, context.l10n.bspScreenLegendPublicFallback),
      (tokens.connectedAccent, context.l10n.bspScreenLegendBspOrCustom),
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

  Widget _earningsFooter(GlassTokens tokens) {
    return GestureDetector(
      onTap: _openTreasury,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: tokens.glassFill,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: tokens.borderSubtle),
        ),
        child: Row(
          children: [
            Icon(Icons.account_balance_rounded,
                size: 16, color: tokens.connectedAccent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                context.l10n.bspScreenEarningsFooter,
                style: TextStyle(
                  fontFamily: 'SpaceGrotesk',
                  fontSize: 12,
                  color: tokens.textDim,
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 18, color: tokens.textDim),
          ],
        ),
      ),
    );
  }

  static String _formatPosWei(BigInt? wei) {
    if (wei == null) return '—';
    final tokens = wei.toDouble() / 1e18;
    return '${tokens.toStringAsFixed(2)} OX';
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
            label: context.l10n.bspScreenRegisterBsp,
            icon: Icons.add_circle_outline,
            onTap: _showRegisterBspSheet,
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
}

class _BspCard extends StatelessWidget {
  final _BspInfo bsp;
  final List<String> badges;
  final VoidCallback? onConnect;
  final bool isActive;
  final Contact? ownerContact;

  const _BspCard({
    required this.bsp,
    this.badges = const [],
    this.onConnect,
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
    final hasActions = onConnect != null;
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
                                bsp.title.isNotEmpty ? bsp.title : bsp.slug,
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
                          '${bsp.slug}${bsp.region.isNotEmpty ? '  ·  ${bsp.region}' : ''}',
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
              _kvRow(tokens, context.l10n.bspScreenLabelRpc,
                  _truncateUrl(bsp.apiUrl.isEmpty ? '—' : bsp.apiUrl)),
              const SizedBox(height: 8),
              _runByRow(context, tokens),
              if (_subsLine(context, bsp) != null) ...[
                const SizedBox(height: 8),
                _kvRow(tokens, context.l10n.bspScreenSubs, _subsLine(context, bsp)!),
              ],
              if (hasActions) ...[
                const SizedBox(height: 12),
                _actionRow(context),
              ],
            ],
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
                ? context.l10n.bspScreenConnected
                : context.l10n.bspScreenConnect,
            icon: Icons.link,
            onTap: isActive ? null : onConnect,
          ),
      ],
    );
  }

  Widget _runByRow(BuildContext context, GlassTokens tokens) {
    final name = ownerContact?.publicosDisplayName ??
        ownerContact?.displayName ??
        _truncateAddress(bsp.owner.eip55With0x);
    return Row(
      children: [
        SizedBox(
          width: 50,
          child: Text(
            context.l10n.bspScreenRunBy,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: tokens.textDim,
            ),
          ),
        ),
        GlassContactIcon(
          contact: ownerContact,
          address: bsp.owner.eip55With0x,
          size: 20,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: tokens.starkWhite,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ],
    );
  }

  /// One-line subscriber summary for the card. Returns `null` when no count is
  /// available (don't render the row). Only the subscriber count is shown,
  /// with no min-subscriber gate framing.
  static String? _subsLine(BuildContext context, _BspInfo bsp) {
    final count = bsp.subscriberCount;
    if (count == null) return null;
    final n = count.toInt();
    return context.l10n.bspScreenSubscriberCount(n);
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
}

class _CustomRpcCard extends StatelessWidget {
  final RpcEndpointEntry entry;
  final bool isActive;
  final VoidCallback? onConnect;
  final VoidCallback? onDelete;

  const _CustomRpcCard({
    required this.entry,
    required this.isActive,
    this.onConnect,
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
                      context.l10n.bspScreenCustomRpcSubtitle,
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
                  context.l10n.bspScreenLabelUrl,
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
                      ? context.l10n.bspScreenConnected
                      : context.l10n.bspScreenConnect,
                  icon: Icons.link,
                  onTap: isActive ? null : onConnect,
                ),
              if (onConnect != null && onDelete != null)
                const SizedBox(width: 8),
              if (onDelete != null)
                _CardActionButton(
                  label: context.l10n.bspScreenDelete,
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

class _RegisterBspSheet extends StatefulWidget {
  const _RegisterBspSheet();

  @override
  State<_RegisterBspSheet> createState() => _RegisterBspSheetState();
}

class _RegisterBspSheetState extends State<_RegisterBspSheet> {
  GlassTokens get tokens => GlassTokens.of(context);

  final _formKey = GlobalKey<FormState>();
  final _slug = TextEditingController();
  final _title = TextEditingController();
  final _rpcUrl = TextEditingController();
  final _region = TextEditingController();
  final _website = TextEditingController();

  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _slug.dispose();
    _title.dispose();
    _rpcUrl.dispose();
    _region.dispose();
    _website.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!_formKey.currentState!.validate()) return;
    final creds = PublicOS.currentBlockchainPrivateKey;
    if (creds == null) {
      setState(() => _error = context.l10n.bspScreenNoActiveSession);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final slug = _slug.text.trim();
      final title = _title.text.trim();
      final apiUrl = _rpcUrl.text.trim();
      final region = _region.text.trim();
      final website = _website.text.trim();

      final pointerTypes = <String>[];
      final pointerValues = <String>[];
      if (website.isNotEmpty) {
        pointerTypes.add('website');
        pointerValues.add(website);
      }

      final txHash = await PublicOSBsp.bspRegistryManagerContract
          .registerBSPWithPointers(
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

      final ok = await TxUtils.waitForReceipt(txHash, label: 'registerBSP');
      if (!ok) {
        throw Exception('Registration reverted on-chain');
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = TxUtils.decodeRevertReason(e) ?? localizedError(context.l10n, e);
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
                context.l10n.bspScreenRegisterBsp,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                  color: tokens.textDim,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.bspScreenRegisterTitle,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: tokens.starkWhite,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                context.l10n.bspScreenRegisterSubtitle,
                style: TextStyle(fontSize: 12, color: tokens.textDim),
              ),
              const SizedBox(height: 22),
              _SheetField(
                controller: _slug,
                label: context.l10n.bspScreenFieldSlug,
                hint: context.l10n.bspScreenSlugHint,
                helper: context.l10n.bspScreenSlugHelper,
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
                  if (s.isEmpty) return context.l10n.bspScreenSlugRequired;
                  if (!RegExp(r'^[a-z0-9][a-z0-9_-]{2,31}$').hasMatch(s)) {
                    return context.l10n.bspScreenSlugInvalid;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),
              _SheetField(
                controller: _title,
                label: context.l10n.bspScreenFieldTitle,
                hint: context.l10n.bspScreenTitleHint,
                enabled: !_submitting,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? context.l10n.bspScreenTitleRequired
                    : null,
              ),
              const SizedBox(height: 14),
              _SheetField(
                controller: _rpcUrl,
                label: context.l10n.bspScreenFieldRpcUrl,
                hint: 'https://rpc.example.com',
                enabled: !_submitting,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? context.l10n.bspScreenRpcUrlRequired
                    : null,
              ),
              const SizedBox(height: 14),
              _SheetField(
                controller: _region,
                label: context.l10n.bspScreenFieldRegion,
                hint: context.l10n.bspScreenRegionHint,
                enabled: !_submitting,
              ),
              const SizedBox(height: 14),
              _SheetField(
                controller: _website,
                label: context.l10n.bspScreenFieldWebsite,
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
                          ? context.l10n.bspScreenRegistering
                          : context.l10n.bspScreenRegister,
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

class _AddCustomRpcSheet extends StatefulWidget {
  const _AddCustomRpcSheet();

  @override
  State<_AddCustomRpcSheet> createState() => _AddCustomRpcSheetState();
}

class _AddCustomRpcSheetState extends State<_AddCustomRpcSheet> {
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
      final result = await PublicOSBsp.addRpcServer(
        url,
        name: nameText.isNotEmpty ? nameText : null,
      );
      if (result == null) {
        throw Exception('Could not connect to this RPC');
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
              context.l10n.bspScreenAddCustomRpc,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
                color: tokens.textDim,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.bspScreenAddRpcTitle,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: tokens.starkWhite,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.bspScreenAddRpcSubtitle,
              style: TextStyle(fontSize: 12, color: tokens.textDim),
            ),
            const SizedBox(height: 22),
            _SheetField(
              controller: _name,
              label: context.l10n.bspScreenFieldName,
              hint: context.l10n.bspScreenNameHint,
              enabled: !_submitting,
            ),
            const SizedBox(height: 14),
            _SheetField(
              controller: _url,
              label: context.l10n.bspScreenFieldRpcUrl,
              hint: 'https://...',
              enabled: !_submitting,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? context.l10n.bspScreenUrlRequired
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
                        ? context.l10n.bspScreenTesting
                        : context.l10n.bspScreenAdd,
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
