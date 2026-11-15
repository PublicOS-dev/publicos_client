// Enum for identifying which type of identifier is being used
enum ContactIdentifierType {
  publicosAddress,
  xmtpInboxId,
  xmtpConversationTopic, // New value
}

enum BrowserTab {
  profile,
  chat,
  management,
  settings,
  webview,
  channel,
  app;

  static BrowserTab fromString(String value) {
    return BrowserTab.values.firstWhere(
      (tab) => tab.name == value,
      orElse: () => BrowserTab.profile,
    );
  }
}

/// Legacy route constants — kept for backward compatibility during migration.
/// New code should use AppNav helpers from router_helpers.dart.
@Deprecated('Use AppNav helpers from router_helpers.dart instead')
class AppRoutes {
  static const String explorer = '/';
  static const String browser = '/browser';
}
