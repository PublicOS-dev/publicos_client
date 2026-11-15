import 'package:flutter/material.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:publicos_client/components/phigital_bottom_sheet.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/components/glass_contact_icon.dart';
import 'package:publicos_client/components/providers/provider_config.dart';
import 'package:publicos_client/providers/theme_provider.dart';
import 'package:publicos_client/router_helpers.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';

/// Data holder for a resolved provider entry.
class _ProviderEntry {
  final String slug;
  final String title;
  final EthereumAddress owner;
  Contact? ownerContact;

  _ProviderEntry({
    required this.slug,
    required this.title,
    required this.owner,
    this.ownerContact,
  });
}

class ProviderDirectorySheet extends StatefulWidget {
  final ProviderConfig config;
  final String? currentSlug;
  final bool isCommitmentActive;
  final VoidCallback? onChanged;

  const ProviderDirectorySheet({
    super.key,
    required this.config,
    this.currentSlug,
    this.isCommitmentActive = false,
    this.onChanged,
  });

  static Future<void> show(
    BuildContext context,
    ProviderConfig config, {
    String? currentSlug,
    bool isCommitmentActive = false,
    VoidCallback? onChanged,
  }) {
    return showPhigitalBottomSheet(
      context: context,
      useDraggable: true,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, isDark) => ProviderDirectorySheet(
        config: config,
        currentSlug: currentSlug,
        isCommitmentActive: isCommitmentActive,
        onChanged: onChanged,
      ),
    );
  }

  @override
  State<ProviderDirectorySheet> createState() => _ProviderDirectorySheetState();
}

class _ProviderDirectorySheetState extends State<ProviderDirectorySheet> {
  static const int _pageSize = 20;

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  List<_ProviderEntry> _providers = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  int _offset = 0;
  bool _isSearching = false;
  Object? _error;

  // Detail expansion
  String? _expandedSlug;
  List<String> _expandedPointerTypes = [];
  List<String> _expandedPointerValues = [];
  bool _isLoadingPointers = false;

  // Subscribe/change in progress
  bool _isSubscribing = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadInitialPage();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  bool get _isBSP => widget.config.typeName == 'BSP';

  // ── Data loading ──

  Future<void> _loadInitialPage() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _providers = [];
      _offset = 0;
      _hasMore = true;
    });

    try {
      final slugs = await _fetchSlugs(BigInt.zero, BigInt.from(_pageSize));
      if (!mounted) return;

      if (slugs.isEmpty) {
        setState(() {
          _isLoading = false;
          _hasMore = false;
        });
        return;
      }

      final entries = await _resolveEntries(slugs);
      if (!mounted) return;

      setState(() {
        _providers = entries;
        _offset = slugs.length;
        _hasMore = slugs.length == _pageSize;
        _isLoading = false;
      });

      _resolveOwnerContacts(entries);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e;
      });
    }
  }

  Future<void> _loadNextPage() async {
    if (_isLoadingMore || !_hasMore || _isSearching) return;

    setState(() => _isLoadingMore = true);

    try {
      final slugs = await _fetchSlugs(
        BigInt.from(_offset),
        BigInt.from(_pageSize),
      );
      if (!mounted) return;

      if (slugs.isEmpty) {
        setState(() {
          _isLoadingMore = false;
          _hasMore = false;
        });
        return;
      }

      final entries = await _resolveEntries(slugs);
      if (!mounted) return;

      setState(() {
        _providers.addAll(entries);
        _offset += slugs.length;
        _hasMore = slugs.length == _pageSize;
        _isLoadingMore = false;
      });

      _resolveOwnerContacts(entries);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingMore = false);
    }
  }

  Future<List<String>> _fetchSlugs(BigInt offset, BigInt limit) async {
    if (_isBSP) {
      return PublicOSBsp.bspRegistryMemoryContract
          .getBSPSlugs((offset: offset, limit: limit));
    } else {
      return PublicOSBsp.socialServerRegistryMemoryContract
          .getSocialServerSlugs((offset: offset, limit: limit));
    }
  }

  Future<List<_ProviderEntry>> _resolveEntries(List<String> slugs) async {
    final entries = <_ProviderEntry>[];
    for (final slug in slugs) {
      try {
        final data = _isBSP
            ? await PublicOSBsp.bspRegistryMemoryContract
                .getBSPBySlug((slug: slug))
            : await PublicOSBsp.socialServerRegistryMemoryContract
                .getSocialServerBySlug((slug: slug));

        // data is a struct tuple: [exists, slug, title, apiUrl, region, owner]
        final asList = data as List;
        final exists = asList[0] as bool;
        if (!exists) continue;

        entries.add(_ProviderEntry(
          slug: asList[1] as String,
          title: asList[2] as String,
          owner: asList[5] as EthereumAddress,
        ));
      } catch (e) {
        // Skip entries that fail to resolve
        debugPrint('[PROVIDER_DIR] Failed to resolve slug "$slug": $e');
      }
    }
    return entries;
  }

  Future<void> _resolveOwnerContacts(List<_ProviderEntry> entries) async {
    for (final entry in entries) {
      try {
        final contact =
            await PublicOSContacts.searchContacts(entry.owner.eip55With0x);
        if (!mounted) return;
        if (contact != null) {
          setState(() => entry.ownerContact = contact);
        }
      } catch (_) {}
    }
  }

  // ── Search ──

  Future<void> _onSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      _clearSearch();
      return;
    }

    setState(() {
      _isSearching = true;
      _isLoading = true;
      _error = null;
      _providers = [];
      _hasMore = false;
    });

    try {
      final slugs = _isBSP
          ? await PublicOSBsp.bspRegistryMemoryContract
              .searchByTitle((title: trimmed))
          : await PublicOSBsp.socialServerRegistryMemoryContract
              .searchByTitle((title: trimmed));

      if (!mounted) return;

      if (slugs.isEmpty) {
        setState(() => _isLoading = false);
        return;
      }

      final entries = await _resolveEntries(slugs);
      if (!mounted) return;

      setState(() {
        _providers = entries;
        _isLoading = false;
      });

      _resolveOwnerContacts(entries);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e;
      });
    }
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _isSearching = false);
    _loadInitialPage();
  }

  // ── Detail / Pointers ──

  Future<void> _toggleDetail(String slug) async {
    if (_expandedSlug == slug) {
      setState(() {
        _expandedSlug = null;
        _expandedPointerTypes = [];
        _expandedPointerValues = [];
      });
      return;
    }

    setState(() {
      _expandedSlug = slug;
      _expandedPointerTypes = [];
      _expandedPointerValues = [];
      _isLoadingPointers = true;
    });

    try {
      if (_isBSP) {
        final result = await PublicOSBsp.bspRegistryMemoryContract
            .getAllBSPPointers((slug: slug));
        if (!mounted) return;
        setState(() {
          _expandedPointerTypes = result.pointerTypes;
          _expandedPointerValues = result.values;
          _isLoadingPointers = false;
        });
      } else {
        final result = await PublicOSBsp.socialServerRegistryMemoryContract
            .getAllSocialServerPointers((slug: slug));
        if (!mounted) return;
        setState(() {
          _expandedPointerTypes = result.pointerTypes;
          _expandedPointerValues = result.values;
          _isLoadingPointers = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingPointers = false);
    }
  }

  // ── Subscribe / Change ──

  Future<void> _subscribe(String slug) async {
    if (!PublicOS.isAuthenticated) return;

    setState(() => _isSubscribing = true);

    try {
      final credentials = PublicOS.currentBlockchainPrivateKey!;
      final hasExisting = widget.currentSlug != null &&
          widget.currentSlug!.isNotEmpty;

      if (hasExisting) {
        // TODO(glass-port): Core API changed — providerSubscriptionManagerContract removed
        // await PublicOSBsp.providerSubscriptionManagerContract.changeProvider(
        //   (providerType: widget.config.providerType, slug: slug),
        //   credentials: credentials,
        // );
        throw UnimplementedError('changeProvider: Core API changed');
      } else {
        // TODO(glass-port): Core API changed — providerSubscriptionManagerContract removed
        // await PublicOSBsp.providerSubscriptionManagerContract.subscribe(
        //   (providerType: widget.config.providerType, slug: slug),
        //   credentials: credentials,
        // );
        throw UnimplementedError('subscribe: Core API changed');
      }

      if (!mounted) return;

      Navigator.of(context).pop();
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubscribing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedError(context.l10n, e))),
      );
    }
  }

  // ── Scroll listener ──

  void _onScroll() {
    if (_scrollController.position.pixels >
        _scrollController.position.maxScrollExtent - 200) {
      _loadNextPage();
    }
  }

  // ── Helpers ──

  String _truncateAddress(EthereumAddress addr) {
    final hex = addr.eip55With0x;
    if (hex.length <= 10) return hex;
    return '${hex.substring(0, 6)}...${hex.substring(hex.length - 4)}';
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.providerDirectorySheetTitle(
                          widget.config.typeName),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.config.typeLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.dns_outlined,
                color: ThemeProvider.tealPrimary,
                size: 28,
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Search bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: context.l10n.providerDirectorySheetSearchHint,
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: _clearSearch,
                    )
                  : null,
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            onSubmitted: _onSearch,
            onChanged: (value) {
              // Trigger rebuild for suffix icon visibility
              setState(() {});
              if (value.isEmpty && _isSearching) {
                _clearSearch();
              }
            },
            textInputAction: TextInputAction.search,
          ),
        ),

        const SizedBox(height: 16),

        // Content area
        Expanded(
          child: _buildContent(theme),
        ),
      ],
    );
  }

  Widget _buildContent(ThemeData theme) {
    if (_isLoading) {
      return const Center(
        child: PhigitalLoadingWidget(size: 36),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                context.l10n.providerDirectorySheetLoadError,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                localizedError(context.l10n, _error!),
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: _isSearching ? () => _onSearch(_searchController.text) : _loadInitialPage,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(context.l10n.actionRetry),
              ),
            ],
          ),
        ),
      );
    }

    if (_providers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.dns_outlined,
                size: 48,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
              ),
              const SizedBox(height: 16),
              Text(
                _isSearching
                    ? context.l10n.providerDirectorySheetNoResults
                    : context.l10n
                        .providerDirectorySheetEmpty(widget.config.typeName),
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
                textAlign: TextAlign.center,
              ),
              if (_isSearching) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _clearSearch,
                  child: Text(context.l10n.providerDirectorySheetClearSearch),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _providers.length + (_isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _providers.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: PhigitalLoadingWidget(size: 24)),
          );
        }

        final entry = _providers[index];
        final isCurrent = widget.currentSlug == entry.slug;
        final isExpanded = _expandedSlug == entry.slug;

        return _buildProviderItem(theme, entry, isCurrent, isExpanded);
      },
    );
  }

  Widget _buildProviderItem(
    ThemeData theme,
    _ProviderEntry entry,
    bool isCurrent,
    bool isExpanded,
  ) {
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: PhigitalStyle.cardDecoration(isDark),
        child: Column(
          children: [
            // Main row
            InkWell(
              onTap: () => _toggleDetail(entry.slug),
              borderRadius: BorderRadius.circular(PhigitalStyle.radiusCard),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    // Title + slug + owner
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Title row with current chip
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  entry.title,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (isCurrent) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: ThemeProvider.tealPrimary
                                        .withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    context.l10n
                                        .providerDirectorySheetCurrentChip,
                                    style: TextStyle(
                                      color: isDark
                                          ? ThemeProvider.tealLight
                                          : ThemeProvider.tealPrimary,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),

                          const SizedBox(height: 4),

                          // Slug
                          Text(
                            entry.slug,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.5),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),

                          const SizedBox(height: 6),

                          // Owner row
                          _buildOwnerRow(theme, entry),
                        ],
                      ),
                    ),

                    // Expand indicator
                    Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),

            // Expanded detail section
            if (isExpanded) _buildDetailSection(theme, entry, isCurrent, isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildOwnerRow(ThemeData theme, _ProviderEntry entry) {
    final contact = entry.ownerContact;
    final displayName = contact?.displayName ?? _truncateAddress(entry.owner);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Navigator.of(context).pop(); // Close the bottom sheet first
        AppNav.toProfile(context, entry.owner.eip55With0x);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            context.l10n.providerDirectorySheetRunBy,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              fontSize: 12,
            ),
          ),
          if (contact != null) ...[
            GlassContactIcon(contact: contact, size: 24),
            const SizedBox(width: 4),
          ] else ...[
            Icon(
              Icons.person_outline,
              size: 16,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 2),
          ],
          Flexible(
            child: Text(
              displayName,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: theme.colorScheme.primary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailSection(
    ThemeData theme,
    _ProviderEntry entry,
    bool isCurrent,
    bool isDark,
  ) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: PhigitalStyle.subtleTint(isDark),
        border: Border(
          top: BorderSide(
            color: PhigitalStyle.subtleBorder(isDark),
          ),
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Pointers section
          if (_isLoadingPointers)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: PhigitalLoadingWidget(size: 20)),
            )
          else if (_expandedPointerTypes.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                context.l10n.providerDirectorySheetNoPointers,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            )
          else
            ..._buildPointerRows(theme, isDark),

          const SizedBox(height: 14),

          // Action button
          _buildActionButton(theme, entry.slug, isCurrent, isDark),
        ],
      ),
    );
  }

  List<Widget> _buildPointerRows(ThemeData theme, bool isDark) {
    final rows = <Widget>[];
    for (var i = 0; i < _expandedPointerTypes.length; i++) {
      if (i > 0) rows.add(const SizedBox(height: 6));
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 100,
              child: Text(
                _expandedPointerTypes[i],
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  fontSize: 12,
                ),
              ),
            ),
            Expanded(
              child: Text(
                _expandedPointerValues[i],
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }
    return rows;
  }

  Widget _buildActionButton(
    ThemeData theme,
    String slug,
    bool isCurrent,
    bool isDark,
  ) {
    if (isCurrent) {
      return Center(
        child: Text(
          context.l10n.providerDirectorySheetCurrentProvider,
          style: theme.textTheme.bodySmall?.copyWith(
            color: isDark ? ThemeProvider.tealLight : ThemeProvider.tealPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    final hasExisting =
        widget.currentSlug != null && widget.currentSlug!.isNotEmpty;
    final label = hasExisting
        ? context.l10n.providerDirectorySheetChangeToProvider
        : context.l10n.providerDirectorySheetSubscribe;
    final isDisabled = widget.isCommitmentActive || _isSubscribing;

    if (hasExisting) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: isDisabled ? null : () => _subscribe(slug),
          child: _isSubscribing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(label),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: isDisabled ? null : () => _subscribe(slug),
        child: _isSubscribing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(label),
      ),
    );
  }
}
