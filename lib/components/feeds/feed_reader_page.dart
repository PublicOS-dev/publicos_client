import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:publicos_client/components/feeds/add_to_lists_sheet.dart';
import 'package:publicos_client/components/feeds/feed_reader_header.dart';
import 'package:publicos_client/components/feeds/feed_source.dart';
import 'package:publicos_client/components/feeds/posts_list.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';

/// One feed on its own, by URL: "Go to feed" when there's no profile tab to
/// land on. The body is the single-feed
/// surface `PostsList` already is (a roster of one, no list) under the
/// [FeedReaderHeader]; the app bar is Back + the Browser channel tab's follow
/// button + ⋯ (Copy feed URL).
class FeedReaderPage extends StatefulWidget {
  final String feedUrl;
  final String? title;

  /// Where the post was found. Rides into a follow as its provenance.
  final String? foundAtAccountAddress;
  final String? recordKey;

  const FeedReaderPage({
    super.key,
    required this.feedUrl,
    this.title,
    this.foundAtAccountAddress,
    this.recordKey,
  });

  @override
  State<FeedReaderPage> createState() => _FeedReaderPageState();
}

class _FeedReaderPageState extends State<FeedReaderPage> {
  bool _inAnyList = false;

  @override
  void initState() {
    super.initState();
    _checkInList();
  }

  /// Same membership scan as the Browser's channel tab: in ANY list = followed.
  Future<void> _checkInList() async {
    var inAnyList = false;
    try {
      for (final list in await PublicOSFeedLists.getUserLists()) {
        final feeds = await PublicOSFeedLists.getFeedsInList(list.id);
        if (feeds.any((f) => f.feedUrl == widget.feedUrl)) {
          inAnyList = true;
          break;
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _inAnyList = inAnyList);
  }

  Future<void> _follow() async {
    final result = await showAddToListsSheet(
      context,
      feedUrl: widget.feedUrl,
      feedTitle: widget.title,
      feedDescription: null,
      feedFoundAtAccountAddress: widget.foundAtAccountAddress,
      feedRecordKey: widget.recordKey,
    );
    if (result == true) _checkInList();
  }

  Future<void> _copyFeedUrl() async {
    await Clipboard.setData(ClipboardData(text: widget.feedUrl));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.l10n.feedReaderPageFeedUrlCopied),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: tokens.background,
        appBar: AppBar(
          backgroundColor: tokens.background,
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: IconThemeData(color: tokens.starkWhite),
          // The name lives in the header below, beside its favicon — the
          // bar is just Back + the feed's actions.
          actions: [
            IconButton(
              icon: Icon(
                _inAnyList
                    ? Icons.bookmark_added_rounded
                    : Icons.bookmark_add_outlined,
                color: tokens.starkWhite,
              ),
              onPressed: _follow,
            ),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded, color: tokens.starkWhite),
              tooltip: '',
              color: tokens.surfaceDeep,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: tokens.borderSubtle),
              ),
              onSelected: (v) {
                if (v == 'copy') _copyFeedUrl();
              },
              itemBuilder: (_) => [
                PopupMenuItem<String>(
                  value: 'copy',
                  child: Row(
                    children: [
                      Icon(Icons.content_copy_rounded,
                          size: 16, color: tokens.starkWhite),
                      const SizedBox(width: 10),
                      Text(
                        context.l10n.feedReaderPageCopyFeedUrl,
                        style: TextStyle(
                          color: tokens.starkWhite,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FeedReaderHeader(feedUrl: widget.feedUrl, title: widget.title),
            Expanded(
              child: PostsList(
                feeds: [
                  FeedSource(
                    url: widget.feedUrl,
                    title: widget.title,
                    foundAtAccountAddress: widget.foundAtAccountAddress,
                    recordKey: widget.recordKey,
                  ),
                ],
                displayName: widget.title,
                showFullScreenLoader: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
