import 'dart:math';

/// Utility class for emoji handling
class EmojiUtils {
  /// List of emojis suitable for RSS list icons
  static const List<String> rssListEmojis = [
    '📰', '📚', '📖', '📝', '📄', '📃', '📋', '📌', '📍', '📎',
    '🔖', '🗂️', '🗃️', '🗄️', '📦', '📮', '📬', '📭', '📫', '📪',
    '💡', '💭', '💬', '🗨️', '🗯️', '💫', '✨', '⭐', '🌟', '⚡',
    '🔥', '💥', '✅', '❤️', '💙', '💚', '💛', '🧡', '💜', '🖤',
    '🎯', '🎨', '🎭', '🎪', '🎬', '🎮', '🎲', '🎰', '🎳', '🎺',
    '🎸', '🎻', '🎹', '🥁', '🎤', '🎧', '🎵', '🎶', '🎼', '🎙️',
    '📻', '📺', '📷', '📸', '📹', '📽️', '🎥', '💻', '🖥️', '⌨️',
    '🖱️', '🖨️', '💾', '💿', '📱', '☎️', '📞', '📟', '📠', '🔌',
    '🔋', '🕯️', '💵', '💴', '💶', '💷', '💰', '💳', '⚖️', '🔧',
    '🔨', '⚒️', '🛠️', '⛏️', '🔩', '⚙️', '🧰', '🧲', '🔫', '💣',
  ];

  /// Generate a random emoji for a new RSS list
  static String getRandomEmoji() {
    final random = Random();
    return rssListEmojis[random.nextInt(rssListEmojis.length)];
  }

  /// Check if a string is a single emoji
  /// This is a simplified check that works for most common emojis
  static bool isEmoji(String text) {
    if (text.isEmpty) return false;

    // Get the first rune (Unicode character)
    final runes = text.runes.toList();

    // Check if it's a single emoji or emoji sequence (with modifiers/ZWJ)
    // Most emojis are in specific Unicode ranges
    return _isEmojiRune(runes.first) && runes.length <= 10; // Allow for emoji sequences
  }

  /// Check if a single rune is an emoji
  static bool _isEmojiRune(int rune) {
    // Common emoji Unicode ranges
    return (rune >= 0x1F300 && rune <= 0x1F9FF) || // Miscellaneous Symbols and Pictographs, Emoticons, etc.
           (rune >= 0x2600 && rune <= 0x27BF) ||   // Miscellaneous Symbols
           (rune >= 0x2300 && rune <= 0x23FF) ||   // Miscellaneous Technical
           (rune >= 0x2B50 && rune <= 0x2B55) ||   // Stars
           (rune >= 0x1F600 && rune <= 0x1F64F) || // Emoticons
           (rune >= 0x1F680 && rune <= 0x1F6FF) || // Transport and Map Symbols
           (rune >= 0x1F900 && rune <= 0x1F9FF);   // Supplemental Symbols and Pictographs
  }

  /// Validate and clean emoji input
  /// Returns the emoji if valid, null otherwise
  static String? validateEmoji(String? text) {
    if (text == null || text.isEmpty) return null;

    // Trim whitespace
    final trimmed = text.trim();

    // Check if it's an emoji
    if (isEmoji(trimmed)) {
      // Return only the first emoji if there are multiple
      final runes = trimmed.runes.toList();
      if (runes.length == 1) {
        return String.fromCharCode(runes.first);
      } else {
        // For emoji sequences (e.g., skin tone modifiers, ZWJ sequences)
        // Return the full sequence
        return trimmed;
      }
    }

    return null;
  }

  /// Get emoji at index (for emoji picker)
  static String getEmojiAt(int index) {
    if (index < 0 || index >= rssListEmojis.length) {
      return getRandomEmoji();
    }
    return rssListEmojis[index];
  }

  /// Get total number of available emojis
  static int get emojiCount => rssListEmojis.length;
}
