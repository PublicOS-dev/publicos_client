import 'package:flutter/cupertino.dart';
import 'package:publicos_core/publicos_core.dart';

import '../components/feeds/feeds_settings_sheet.dart' show parsePostLayoutMode;
import '../components/feeds/post_card.dart' show PostLayoutMode;
import '../components/feeds/post_detail_page.dart';

/// The app route for a share link that names a post: `/post?url=` with the feed
/// and the found-at tab the link carried, and `link=1` so the page walks the
/// back ladder (a notification's `/post?url=` does not).
String postRouteOf(DeepLink link) {
  final onTab = link.kind == DeepLinkKind.publicosAddress && link.key != null;
  return Uri(path: '/post', queryParameters: {
    'url': link.post!,
    if (link.feed != null) 'feed': link.feed!,
    if (onTab) 'at': link.identifier,
    if (onTab) 'tab': link.key!,
    'link': '1',
  }).toString();
}

/// Fetch a post from its permalink. A `#comment-<uid>` fragment (a social
/// notification's `item_url` for a comment, a reply or a comment reaction)
/// points inside the post and is dropped for the fetch. The post comes from
/// the URL's own host, never the reader's SSP.
Future<Post?> fetchPostFromUrl(String url) async {
  final clean = url.split('#').first;
  if (clean.isEmpty) return null;
  final r = await PublicOSChannels.getPostByUrl(clean);
  return r.data;
}


/// The reader's feed settings for a post opened with no list behind it (a
/// notification tap, a link): the same keys `PostsList`, the explore and the
/// bookmarks views read, so the detail page keeps the reader's layout (wide /
/// compact) and text sizes. Defaults match
/// `PostDetailPage`'s on any miss.
Future<({PostLayoutMode layout, double title, double desc})>
    readerPostSettings() async {
  var layout = PostLayoutMode.compact;
  var title = 16.0;
  var desc = 14.0;
  try {
    final t = await PublicOSSettings.getSetting('rss_feeds_title_text_size');
    final d =
        await PublicOSSettings.getSetting('rss_feeds_description_text_size');
    final l = await PublicOSSettings.getSetting('rss_feeds_layout_mode');
    if (t != null) title = double.tryParse(t.value) ?? title;
    if (d != null) desc = double.tryParse(d.value) ?? desc;
    if (l != null) layout = parsePostLayoutMode(l.value);
  } catch (_) {}
  return (layout: layout, title: title, desc: desc);
}

/// Open a post from its permalink in the detail page. False when the post
/// could not be fetched (gone, private to the reader, server down).
Future<bool> openPostFromUrl(BuildContext context, String url) async {
  final post = await fetchPostFromUrl(url);
  if (post == null || !context.mounted) return false;
  final prefs = await readerPostSettings();
  if (!context.mounted) return false;
  await Navigator.of(context).push(CupertinoPageRoute(
    builder: (_) => PostDetailPage(
      post: post,
      layoutMode: prefs.layout,
      titleTextSize: prefs.title,
      descriptionTextSize: prefs.desc,
    ),
  ));
  return true;
}
