import 'package:flutter/material.dart';
import 'package:publicos_core/publicos_core.dart';

import 'package:publicos_client/components/feeds/post_card.dart'
    show PostLayoutMode;
import 'package:publicos_client/components/feeds/post_detail_page.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/utils/post_links.dart';

/// The `/post?url=` route: a post opened by permalink, from a social
/// notification's tap (`post:<item_url>`). Fetches
/// the post from the URL's own host, then renders the ordinary detail page.
/// Exists as a route so a cold-start tap can be parked as a pending route
/// until the account is selected, like a conversation tap.
class PostFromUrlPage extends StatefulWidget {
  final String url;
  const PostFromUrlPage({super.key, required this.url});

  @override
  State<PostFromUrlPage> createState() => _PostFromUrlPageState();
}

class _PostFromUrlPageState extends State<PostFromUrlPage> {
  Post? _post;
  bool _failed = false;
  ({PostLayoutMode layout, double title, double desc})? _prefs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await fetchPostFromUrl(widget.url);
      // The reader's layout + text sizes: the page has no list behind
      // it to pass them down.
      final prefs = p == null ? null : await readerPostSettings();
      if (!mounted) return;
      setState(() {
        _post = p;
        _prefs = prefs;
        _failed = p == null;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final post = _post;
    if (post != null) {
      final prefs = _prefs;
      return PostDetailPage(
        post: post,
        layoutMode: prefs?.layout ?? PostLayoutMode.compact,
        titleTextSize: prefs?.title ?? 16.0,
        descriptionTextSize: prefs?.desc ?? 14.0,
      );
    }
    final tokens = GlassTokens.of(context);
    return Scaffold(
      backgroundColor: tokens.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: tokens.starkWhite),
      ),
      body: Center(
        child: _failed
            ? Text(
                context.l10n.notificationsScreenPostUnavailable,
                style: TextStyle(color: tokens.textDim, fontSize: 14),
              )
            : const PhigitalLoadingWidget(size: 28, showShadows: false),
      ),
    );
  }
}
