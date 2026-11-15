import 'package:flutter/material.dart';
import 'package:publicos_client/components/contact_banner.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:publicos_client/utils/own_links.dart';

import 'package:publicos_client/components/glass_contact_icon.dart';
import 'package:publicos_client/components/profile/record_button.dart'
    show socialIconForKey, socialDisplayName;
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/router_helpers.dart';
import 'package:publicos_client/theme/glass_theme.dart';

/// A discover row for the feeds tab — same visual language as the messages
/// `ConversationRow` (12%-opacity full-bleed banner + left avatar + name).
/// Capability hints (RSS / Website) derived from the contact's
/// records render as subtle, right-aligned monochrome icons on the name line
/// instead of loud colored pill badges.
///
/// Tapping fires the contact's account in the in-app browser (wired by the
/// parent via [onTap]). Stateful + keep-alive so the avatar doesn't flicker
/// on scroll (see [_DiscoverContactRowState]).
class DiscoverContactRow extends StatefulWidget {
  final Contact contact;
  final VoidCallback? onTap;
  final double iconSize;
  final bool showBanner;

  /// The saved-contacts rows (contacts_view + its settings-sheet preview)
  /// hide the trailing chevron; the feeds discover browser keeps it.
  final bool showChevron;

  const DiscoverContactRow({
    super.key,
    required this.contact,
    this.onTap,
    this.iconSize = 56,
    this.showBanner = true,
    this.showChevron = true,
  });

  @override
  State<DiscoverContactRow> createState() => _DiscoverContactRowState();
}

/// Keep-alive so rows that scroll out of view aren't disposed and rebuilt —
/// otherwise `GlassContactIcon` re-resolves and re-decodes the avatar every
/// time the row scrolls back in, which reads as the icon flickering/reloading.
/// Mirrors `contacts_view.dart`'s `_ContactTile`.
class _DiscoverContactRowState extends State<DiscoverContactRow>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // ── Capability detection (matches the record conventions used across the
  // app: app_settings_page.dart for RSS/Bluesky, browser.dart for tabs).
  // We resolve the FIRST tab of each kind (profile order: ranked first, then
  // unranked — same as `_socials` and `getAllUserRecords`) so its glyph can
  // fire straight into that tab via `AppNav.toTab`, the route the in-app
  // Browser resolves by exact record key. If a contact has several feeds /
  // sites, this lands on the first; the profile's tab strip exposes the rest.
  Record? get _firstFeed => _firstTab(RouterSubtype.channel);
  Record? get _firstWebsite => _firstTab(RouterSubtype.tab);

  Record? _firstTab(RouterSubtype subtype) {
    final all = widget.contact.records
        .where((r) => r.routerSubtype == subtype && !r.isExpired)
        .toList();
    if (all.isEmpty) return null;
    final ranked = all.where((r) => r.rank != null).toList()
      ..sort((a, b) => a.rank!.compareTo(b.rank!));
    final unranked = all.where((r) => r.rank == null).toList();
    return [...ranked, ...unranked].first;
  }

  /// Launchable socials in profile order — ranked (LexoRank) first, then
  /// unranked in chain-enumeration order, mirroring
  /// `PublicOSContacts.getAllUserRecords`. Skips socials with no link (a dead
  /// icon on a press-to-launch strip is confusing) and ones we can't draw
  /// (no branded glyph AND no MaterialIcons codepoint). The trailing grid
  /// caps total slots at 6; capping here too just bounds the list early.
  List<Record> get _socials {
    final all = widget.contact.records
        .where((r) =>
            r.profileSubtype == ProfileSubtype.social &&
            !r.isExpired &&
            (r.link?.trim().isNotEmpty ?? false) &&
            (socialIconForKey(r.key) != null || r.icon != null))
        .toList();
    final ranked = all.where((r) => r.rank != null).toList()
      ..sort((a, b) => a.rank!.compareTo(b.rank!));
    final unranked = all.where((r) => r.rank == null).toList();
    return [...ranked, ...unranked].take(6).toList();
  }

  /// The contact's bio — first non-empty, non-expired `profile.bio` record
  /// (canonical lookup matches profile_page.dart: `ProfileSubtype.text`).
  String? get _bio {
    for (final r in widget.contact.records) {
      if (r.profileSubtype == ProfileSubtype.text &&
          !r.isExpired &&
          r.value.trim().isNotEmpty) {
        return r.value.trim();
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final tokens = GlassTokens.of(context);
    final name =
        widget.contact.publicosDisplayName ?? widget.contact.displayName;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        child: Stack(
          children: [
            if (widget.showBanner)
              Positioned.fill(
                child: Opacity(
                  opacity: 0.12,
                  child: ClipRect(
                    child: ContactBanner(
                      contact: widget.contact,
                      fallback: const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: widget.iconSize + 16),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    GlassContactIcon(
                        contact: widget.contact, size: widget.iconSize),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            name,
                            style: TextStyle(
                              fontFamily: 'SpaceGrotesk',
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              color: tokens.starkWhite,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                          if (_bio != null) ...[
                            const SizedBox(height: 3),
                            Text(
                              _bio!,
                              style: TextStyle(
                                fontFamily: 'SpaceGrotesk',
                                fontSize: 12,
                                color: tokens.textDim,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _TrailingIconGrid(
                      tokens: tokens,
                      address: widget.contact.publicosAddress?.eip55With0x,
                      feed: _firstFeed,
                      website: _firstWebsite,
                      socials: _socials,
                    ),
                    if (widget.showChevron) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 22,
                        color: tokens.textDim,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Trailing 2×3 icon grid — 6 fixed-size slots, top row fills first, rows
/// left-aligned with each other (a Column of two min Rows; a real grid widget
/// is overkill for this). Tab capabilities come FIRST (at most one glyph per
/// type: RSS, Website — same icons the browser tab bar uses), then the
/// contact's socials fill the remaining slots. Quiet monochrome glyphs so the
/// block reads as metadata next to the name rather than competing with it.
/// Renders nothing when the contact has neither.
///
/// The RSS and Website glyphs are TAPPABLE: each fires `AppNav.toTab` into the
/// contact's first feed / website tab in the in-app Browser.
/// The social glyphs stay external (`launchUrl`). When [address] is null
/// (XMTP-only contact) the tab glyphs degrade to passive hints.
class _TrailingIconGrid extends StatelessWidget {
  static const int _maxSlots = 6;
  static const int _perRow = 3;

  final GlassTokens tokens;
  final String? address;
  final Record? feed;
  final Record? website;
  final List<Record> socials;

  const _TrailingIconGrid({
    required this.tokens,
    required this.address,
    required this.feed,
    required this.website,
    required this.socials,
  });

  @override
  Widget build(BuildContext context) {
    final slots = <Widget>[
      if (feed != null)
        _IconSlot(
          tooltip: context.l10n.discoverContactRowRssTooltip,
          glyph: Icon(Icons.rss_feed_rounded, size: 17, color: tokens.textDim),
          onTap: address == null
              ? null
              : () => AppNav.toTab(context, address!, feed!.key, record: feed),
        ),
      if (website != null)
        _IconSlot(
          tooltip: context.l10n.discoverContactRowWebsiteTooltip,
          glyph:
              Icon(Icons.language_rounded, size: 17, color: tokens.textDim),
          onTap: address == null
              ? null
              : () => AppNav.toTab(context, address!, website!.key,
                  record: website),
        ),
      for (final r in socials) _SocialSlot(tokens: tokens, record: r),
    ];
    if (slots.isEmpty) return const SizedBox.shrink();
    final visible = slots.take(_maxSlots).toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: visible.take(_perRow).toList(),
        ),
        if (visible.length > _perRow)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: visible.skip(_perRow).toList(),
          ),
      ],
    );
  }
}

/// One fixed 28×28 grid slot — uniform geometry is what makes the two rows
/// line up into columns. Tooltip preserves the label for accessibility/hover;
/// with [onTap] the whole slot is the hit target.
class _IconSlot extends StatelessWidget {
  final String tooltip;
  final Widget glyph;
  final VoidCallback? onTap;

  const _IconSlot({
    required this.tooltip,
    required this.glyph,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final slot = SizedBox(
      width: 28,
      height: 28,
      child: Center(
        child: Tooltip(message: tooltip, child: glyph),
      ),
    );
    if (onTap == null) return slot;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: slot,
    );
  }
}

/// A social in a grid slot — branded vector if known, MaterialIcons codepoint
/// fallback otherwise (same fallback chain as the profile's `RecordButton`);
/// tap launches the record's link, same as the profile.
class _SocialSlot extends StatelessWidget {
  final GlassTokens tokens;
  final Record record;

  const _SocialSlot({required this.tokens, required this.record});

  Future<void> _launch() async {
    final uri = Uri.tryParse(record.link!);
    if (uri == null) return;
    if (routeOwnLink(uri)) return;
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  @override
  Widget build(BuildContext context) {
    return _IconSlot(
      tooltip: socialDisplayName(record.key),
      onTap: _launch,
      glyph: socialIconForKey(record.key, size: 17, color: tokens.textDim) ??
          Icon(
            IconData(record.icon!, fontFamily: 'MaterialIcons'),
            size: 17,
            color: tokens.textDim,
          ),
    );
  }
}
