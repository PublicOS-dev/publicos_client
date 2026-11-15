import 'package:flutter/cupertino.dart';
import 'package:publicos_core/publicos_core.dart';

import 'package:publicos_client/pages/channel_settings_page.dart';
import 'package:publicos_client/components/feeds/feed_reader_page.dart';

/// Follow notifications point at a CHANNEL, not a post:
/// a follow request's `item_url` is the channel the stranger
/// wants into, an approval's the channel the reader was let into. Two
/// targeted openers, both app-internal (no publicos.dev shape, the web page's
/// three identifier-class prefixes are untouched).

/// Fetch the channel object behind any URL under it, signed when the reader
/// signs there (the owner always does), so the settings page gets the full
/// channel. Null when the URL is not a PublicOS channel or the fetch fails.
Future<Channel?> fetchChannelFromUrl(String url) async {
  final base = channelBaseOf(url);
  if (base == null) return null;
  final uri = Uri.parse(base);
  final segs = uri.pathSegments; // api, owner, channels, slug
  final r = await PublicOSChannels.getChannel(
    ownerAddress: segs[1],
    slug: segs[3],
    serverAddress: uri.origin,
  );
  return r.success ? r.data : null;
}

/// A follow request: open the owner's settings for that channel with the
/// request queue showing (drawer 1, the Private editor open). False when the
/// channel could not be fetched.
Future<bool> openChannelRequestsFromUrl(BuildContext context, String url) async {
  final channel = await fetchChannelFromUrl(url);
  if (channel == null || !context.mounted) return false;
  await Navigator.of(context).push(CupertinoPageRoute(
    builder: (_) => ChannelSettingsPage(channel: channel, openRequests: true),
  ));
  return true;
}

/// A follow approval: read the channel the reader was let into, the feed on
/// its own (a profile LISTS a channel, nothing finds the listing tab from the
/// channel, see go_to_feed.dart). False when the URL is not a channel.
Future<bool> openChannelFeedFromUrl(BuildContext context, String url) async {
  final base = channelBaseOf(url);
  if (base == null || !context.mounted) return false;
  final slug = Uri.parse(base).pathSegments[3];
  await Navigator.of(context).push(CupertinoPageRoute(
    builder: (_) => FeedReaderPage(feedUrl: '$base/json', title: slug),
  ));
  return true;
}
