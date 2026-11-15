import 'package:publicos_core/publicos_core.dart';
import 'package:flutter/material.dart';
import 'package:publicos_client/components/glass_contact_icon.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';

class EditListBottomSheet extends StatefulWidget {
  final ListWithFeeds listWithFeeds;
  final Function()? onListUpdated;

  const EditListBottomSheet({
    super.key,
    required this.listWithFeeds,
    this.onListUpdated,
  });

  @override
  State<EditListBottomSheet> createState() => _EditListBottomSheetState();
}

class _EditListBottomSheetState extends State<EditListBottomSheet> {
  late List<ListFeed> _feeds;
  bool _isLoading = false;
  Map<String, Contact> _resolvedContacts = {};

  @override
  void initState() {
    super.initState();
    _feeds = List.from(widget.listWithFeeds.feeds);
    _resolveContactsForFeeds();
  }

  /// Resolve contacts for all unique addresses in the feeds
  Future<void> _resolveContactsForFeeds() async {
    if (_feeds.isEmpty) return;

    // Gather all unique addresses
    final Set<String> uniqueAddresses = {};
    // for (final feed in _feeds) {
    //   if (feed. != null && feed.feedFoundAtAccountAddress!.isNotEmpty) {
    //     uniqueAddresses.add(feed.feedFoundAtAccountAddress!);
    //   }
    // }

    if (uniqueAddresses.isEmpty) return;

    print('[EDIT_LIST_DEBUG] Resolving contacts for ${uniqueAddresses.length} unique addresses');

    // Resolve contacts for all addresses
    final Map<String, Contact> newResolvedContacts = {};
    for (final address in uniqueAddresses) {
      try {
        final contact = await PublicOSContacts.searchContacts(address);
        if (contact != null) {
          newResolvedContacts[address] = contact;
          print('[EDIT_LIST_DEBUG] Resolved contact for $address: ${contact.displayName}');
        } else {
          print('[EDIT_LIST_DEBUG] No local contact found for $address');
        }
      } catch (e) {
        print('[EDIT_LIST_DEBUG] Error resolving contact for $address: $e');
      }
    }

    // Update state
    if (mounted) {
      setState(() {
        _resolvedContacts = newResolvedContacts;
      });
    }
  }

  Future<void> _removeFeed(ListFeed feed) async {
    final l10n = context.l10n;
    setState(() => _isLoading = true);

    try {
      final success = await PublicOSFeedLists.removeFeedFromList(
        widget.listWithFeeds.list.id,
        feed.id,
      );

      if (success && mounted) {
        setState(() {
          _feeds.removeWhere((f) => f.id == feed.id);
        });
        // Re-resolve contacts after removing a feed
        _resolveContactsForFeeds();
        widget.onListUpdated?.call();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.editListBottomSheetRemovedFromList(
              feed.feedTitle ?? feed.feedUrl,
            )),
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.editListBottomSheetRemoveFailed)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(localizedError(
              l10n,
              e,
              fallback: l10n.editListBottomSheetRemoveFeedError,
            )),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showRemoveConfirmation(ListFeed feed) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
        title: Text(context.l10n.editListBottomSheetRemoveFeedTitle),
        content: Text(
          context.l10n.editListBottomSheetRemoveConfirm(
            feed.feedTitle ?? feed.feedUrl,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.dlgCancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _removeFeed(feed);
            },
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
            ),
            child: Text(context.l10n.editListBottomSheetRemove),
          ),
        ],
      ),
    );
  }

  Widget _buildFeedIcon(ListFeed feed, ThemeData theme) {
    // Check if we have an originating account address
    if (feed.feedFoundAtAccountAddress != null && feed.feedFoundAtAccountAddress!.isNotEmpty) {
      // Check if we have a resolved contact for this address
      final contact = _resolvedContacts[feed.feedFoundAtAccountAddress!];
      if (contact != null) {
        // Show contact icon with yellow border
        return Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: Colors.amber,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: GlassContactIcon(
            contact: contact,
            size: 36,
          ),
        );
      }
    }

    // Fallback to RSS feed icon with yellow border and yellow icon
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        border: Border.all(
          color: Colors.amber,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Icon(
        Icons.rss_feed,
        color: Colors.amber,
        size: 20,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title and list info
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.listWithFeeds.list.name,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.editListBottomSheetFeedCount(_feeds.length),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha:0.7),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.list_alt_rounded,
                color: theme.colorScheme.primary,
                size: 32,
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Feeds list
          if (_feeds.isEmpty)
            Container(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  Icon(
                    Icons.rss_feed_outlined,
                    size: 48,
                    color: theme.colorScheme.onSurface.withValues(alpha:0.4),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    context.l10n.editListBottomSheetNoFeeds,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha:0.7),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.l10n.editListBottomSheetEmptyHint,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha:0.5),
                    ),
                  ),
                ],
              ),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.4,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _feeds.length,
                separatorBuilder: (context, index) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final feed = _feeds[index];
                  return Card(
                    child: ListTile(
                      leading: _buildFeedIcon(feed, theme),
                      title: Text(
                        feed.feedTitle ?? context.l10n.editListBottomSheetRssFeed,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        feed.feedUrl,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha:0.6),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        onPressed: _isLoading ? null : () => _showRemoveConfirmation(feed),
                        icon: Icon(
                          Icons.delete_outline,
                          color: Colors.red.withValues(alpha:_isLoading ? 0.5 : 1.0),
                        ),
                        tooltip: context.l10n.editListBottomSheetRemoveTooltip,
                      ),
                    ),
                  );
                },
              ),
            ),

          const SizedBox(height: 24),

          // Close button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.surface,
                foregroundColor: theme.colorScheme.onSurface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(context.l10n.editListBottomSheetDone),
            ),
          ),
        ],
      ),
    );
  }
}