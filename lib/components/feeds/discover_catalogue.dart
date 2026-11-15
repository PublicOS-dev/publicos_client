import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// In-app Discover catalogue: a hand-curated, hardcoded set of RSS feeds
/// grouped into categories, shipped as `assets/discover/catalogue.json`.
///
/// v1 is fully static — no API, no server endpoint. The JSON shape is
/// deliberately tooling-free (Material icon names as strings, resolved by
/// [iconForName]) so the catalogue can grow by editing the asset alone.
/// Later this can swap `rootBundle.loadString` for an HTTP fetch of the
/// same shape without touching consumers.
class DiscoverFeed {
  final String title;
  final String url;
  final String? siteUrl;
  final String? description;

  const DiscoverFeed({
    required this.title,
    required this.url,
    this.siteUrl,
    this.description,
  });

  factory DiscoverFeed.fromJson(Map<String, dynamic> json) {
    return DiscoverFeed(
      title: json['title'] as String? ?? '',
      url: json['url'] as String? ?? '',
      siteUrl: json['site_url'] as String?,
      description: json['description'] as String?,
    );
  }
}

class DiscoverCategory {
  final String slug;
  final String title;
  final String iconName;
  final List<DiscoverFeed> feeds;

  const DiscoverCategory({
    required this.slug,
    required this.title,
    required this.iconName,
    required this.feeds,
  });

  factory DiscoverCategory.fromJson(Map<String, dynamic> json) {
    final rawFeeds = (json['feeds'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(DiscoverFeed.fromJson)
        .where((f) => f.url.isNotEmpty)
        .toList();
    return DiscoverCategory(
      slug: json['slug'] as String? ?? '',
      title: json['title'] as String? ?? '',
      iconName: json['icon'] as String? ?? 'rss_feed',
      feeds: rawFeeds,
    );
  }
}

class DiscoverCatalogue {
  static const _assetPath = 'assets/discover/catalogue.json';

  /// In-memory cache — the asset never changes at runtime, so load once.
  static List<DiscoverCategory>? _cache;

  /// Load and parse the catalogue. Returns an empty list (never throws) if
  /// the asset is missing or malformed — Discover degrades to an empty
  /// state rather than crashing the feeds tab.
  static Future<List<DiscoverCategory>> load() async {
    if (_cache != null) return _cache!;
    try {
      final raw = await rootBundle.loadString(_assetPath);
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final categories = (json['categories'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(DiscoverCategory.fromJson)
          .where((c) => c.feeds.isNotEmpty)
          .toList();
      _cache = categories;
      return categories;
    } catch (_) {
      _cache = const [];
      return const [];
    }
  }

  /// Resolve a Material icon name (from the catalogue JSON) to an [IconData].
  /// Unknown names fall back to a generic RSS glyph — keeps the asset
  /// tooling-free without risking a crash on a typo.
  static IconData iconForName(String name) {
    switch (name) {
      case 'memory':
        return Icons.memory_rounded;
      case 'public':
        return Icons.public_rounded;
      case 'currency_bitcoin':
        return Icons.currency_bitcoin_rounded;
      case 'palette':
        return Icons.palette_rounded;
      case 'science':
        return Icons.science_rounded;
      case 'newspaper':
        return Icons.newspaper_rounded;
      case 'sports_basketball':
        return Icons.sports_basketball_rounded;
      case 'movie':
        return Icons.movie_rounded;
      case 'music_note':
        return Icons.music_note_rounded;
      case 'restaurant':
        return Icons.restaurant_rounded;
      default:
        return Icons.rss_feed_rounded;
    }
  }
}
