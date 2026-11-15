/// Utility class for parsing images from RSS feed content
class RssImageParser {
  /// Extract image URLs from RSS post content
  ///
  /// Uses a multi-strategy approach to find images:
  /// 1. Extract from HTML <img> tags in content (WordPress, Ghost, etc.)
  /// 2. Limit to first 3 images to avoid showing too many
  ///
  /// Returns a list of unique image URLs
  static List<String> extractImages({
    String? imageUrl,
    String? htmlContent,
  }) {
    final List<String> images = [];

    // Extract images from HTML content (most common)
    if (htmlContent != null && htmlContent.isNotEmpty) {
      final htmlImages = _extractImagesFromHtml(htmlContent);

      // Add up to 3 unique images
      for (final img in htmlImages) {
        if (!images.contains(img) && images.length < 3) {
          images.add(img);
        }
      }
    }

    return images;
  }

  /// Extract image URLs from HTML content
  /// Looks for <img src="..." /> tags
  static List<String> _extractImagesFromHtml(String html) {
    final List<String> images = [];

    // Regular expression to match img tags
    // Handles single quotes, double quotes, and various formats
    final imgRegex = RegExp(
      r'<img[^>]+src\s*=\s*["\x27]([^"\x27]+)["\x27][^>]*>',
      caseSensitive: false,
    );

    final matches = imgRegex.allMatches(html);

    for (final match in matches) {
      final imageUrl = match.group(1);
      if (imageUrl != null && imageUrl.isNotEmpty) {
        // Filter out tracking pixels, placeholders, and tiny images
        if (_isValidImage(imageUrl)) {
          images.add(imageUrl);
        }
      }
    }

    return images;
  }

  /// Check if an image URL is valid for display
  /// Filters out common tracking pixels and invalid images
  static bool _isValidImage(String url) {
    // Skip if URL is too short
    if (url.length < 10) return false;

    // Skip common tracking pixel patterns
    final trackingPatterns = [
      'pixel',
      'tracking',
      '1x1',
      'transparent.gif',
      'spacer.gif',
    ];

    final lowerUrl = url.toLowerCase();
    for (final pattern in trackingPatterns) {
      if (lowerUrl.contains(pattern)) {
        return false;
      }
    }

    // Only accept common image formats
    final imageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.svg'];
    final hasImageExtension = imageExtensions.any((ext) => lowerUrl.contains(ext));

    // Also accept URLs that don't have extensions but are from known image hosts
    final knownImageHosts = [
      'substackcdn.com/image/',
      'i0.wp.com',
      'i1.wp.com',
      'i2.wp.com',
      'georgerrmartin.com',
      'blogs.microsoft.com/wp-content',
      'profgalloway.com/wp-content',
    ];

    final isFromImageHost = knownImageHosts.any((host) => lowerUrl.contains(host));

    return hasImageExtension || isFromImageHost;
  }
}
