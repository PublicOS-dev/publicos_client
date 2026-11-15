import 'package:flutter/material.dart';
import 'package:publicos_core/publicos_core.dart';

import 'package:publicos_client/components/feeds/feed_reader_page.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/pages/channel_settings_page.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/utils/channel_links.dart';

/// The `/channel-requests?url=` and `/channel?url=` routes: a channel opened
/// by URL from a follow notification's tap. With
/// [requests] the owner's settings page lands on its request queue (the
/// channel object is fetched first, signed); without, the channel's feed.
/// A route, like `/post`, so a cold-start tap can be parked as a pending
/// route until the account is selected.
class ChannelFromUrlPage extends StatefulWidget {
  final String url;
  final bool requests;
  const ChannelFromUrlPage({super.key, required this.url, required this.requests});

  @override
  State<ChannelFromUrlPage> createState() => _ChannelFromUrlPageState();
}

class _ChannelFromUrlPageState extends State<ChannelFromUrlPage> {
  Channel? _channel;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.requests) {
      _load();
    } else {
      _failed = channelBaseOf(widget.url) == null;
    }
  }

  Future<void> _load() async {
    try {
      final c = await fetchChannelFromUrl(widget.url);
      if (!mounted) return;
      setState(() {
        _channel = c;
        _failed = c == null;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.requests && !_failed) {
      final base = channelBaseOf(widget.url)!;
      return FeedReaderPage(
        feedUrl: '$base/json',
        title: Uri.parse(base).pathSegments[3],
      );
    }
    final channel = _channel;
    if (channel != null) {
      return ChannelSettingsPage(channel: channel, openRequests: true);
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
                context.l10n.notificationsScreenChannelUnavailable,
                style: TextStyle(color: tokens.textDim, fontSize: 14),
              )
            : const PhigitalLoadingWidget(size: 28, showShadows: false),
      ),
    );
  }
}
