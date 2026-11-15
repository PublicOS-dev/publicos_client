/// In-app routing for links our own code is about to open.
///
/// A `https://publicos.dev` link under one of the three claimed prefixes is
/// one the OS hands back to this app. Android does that round trip, but iOS
/// never re-enters an app that opens its own universal link: it goes to
/// Safari. So every place that launches a URL
/// asks [routeOwnLink] first. On a match the link takes the same path an
/// inbound link takes (the `onDeepLink` handler in `app_initializer.dart`),
/// minus the trip out to the OS.
library;

/// The prefixes the OS claims for this app: AndroidManifest intent filters
/// and the live `apple-app-site-association`. Keep the three in step. A
/// `publicos.dev` path outside them (the homepage, /developers, …) is a web
/// page and still opens in the browser.
const List<String> _kClaimedPrefixes = [
  '/publicosAddress/',
  '/inboxId/',
  '/conversationTopic/',
];

/// Set by `AppInitializer.setupDeepLinkChannel` to the inbound-link handler.
/// Null before boot wires it, and then nothing is intercepted.
bool Function(String url)? ownLinkRouter;

/// Route [uri] in-app when it is one of our claimed links. Returns false
/// otherwise, and the caller launches it exactly as before.
bool routeOwnLink(Uri uri) {
  if (uri.scheme != 'https' || uri.host != 'publicos.dev') return false;
  if (!_kClaimedPrefixes.any(uri.path.startsWith)) return false;
  return ownLinkRouter?.call(uri.toString()) ?? false;
}
