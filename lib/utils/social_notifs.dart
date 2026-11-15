import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:publicos_core/publicos_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import 'notification_kinds.dart';

/// Headless helpers for social notifications:
/// the inbox pull, the OS popup, and the localizations loader the
/// background isolates share. No widget, no context.

/// Loads the active locale's [AppLocalizations] for a headless isolate (the
/// 15-min worker, the FCM background handler). Reads the same `app_locale`
/// pref as LocaleProvider; "System default" follows the device locale,
/// falling back to English.
Future<AppLocalizations> isolateLocalizations() async {
  var code = 'en';
  try {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('app_locale');
    if (saved == 'en' || saved == 'es') {
      code = saved!;
    } else {
      final dev = PlatformDispatcher.instance.locale.languageCode;
      code = dev == 'es' ? 'es' : 'en';
    }
  } catch (_) {
    // Default to English on any failure.
  }
  return AppLocalizations.delegate.load(Locale(code));
}

/// `isSelf` / `nameOf` over the local contact cache, the resolvers
/// [notifSentence] takes. "You" for the session's own account, the contact's
/// display name, else the short address.
///
/// [lookup] (a quick resolve: one direct read of the account's display name;
/// if it returns a name it is used, if not nothing else is consulted and the
/// address is shown): the actor
/// addresses the caller is about to name. Each one the cache misses gets ONE
/// chain read, `AccountMemory.getDisplayName`, through the web3 client the
/// isolate already holds (the chain isolate boots on the public RPC;
/// [PublicOSContacts.getPublicosDisplayNameByAccountAddress] caps it at 5 s),
/// all in parallel, [chainBudget] in total. A name is used; anything else
/// falls to the short address. Nothing is saved: the contact cache stays the
/// user's.
Future<({bool Function(String) isSelf, String Function(String) nameOf})>
    contactNameResolvers(
  String selfAddr,
  AppLocalizations l10n, {
  Iterable<String> lookup = const [],
  Duration chainBudget = const Duration(seconds: 3),
}) async {
  final byAddr = <String, Contact>{};
  try {
    for (final c in await PublicOSContacts.getStoredContacts()) {
      final a = c.publicosAddress?.eip55With0x.toLowerCase();
      if (a != null) byAddr[a] = c;
    }
  } catch (_) {
    // An unreadable cache leaves every actor as a short address.
  }
  final selfLower = selfAddr.toLowerCase();
  bool isSelf(String a) => a.toLowerCase() == selfLower;
  String? cached(String a) {
    final c = byAddr[a.toLowerCase()];
    final n = c?.publicosDisplayName ?? c?.displayName;
    return (n != null && n.trim().isNotEmpty) ? n.trim() : null;
  }

  // One chain read per actor the cache does not know.
  final fromChain = <String, String>{};
  final missing = {
    for (final a in lookup)
      if (!isSelf(a) && cached(a) == null && _isAddress(a)) a.toLowerCase(),
  };
  if (missing.isNotEmpty) {
    try {
      await Future.wait(missing.map((a) async {
        final name = await PublicOSContacts.getPublicosDisplayNameByAccountAddress(
          EthereumAddress.fromHex(a),
        );
        if (name != null && name.trim().isNotEmpty) fromChain[a] = name.trim();
      })).timeout(chainBudget);
    } catch (e) {
      // Budget spent or no client in this isolate: the misses stay addresses.
      debugPrint('[social] F8 name lookup: $e');
    }
  }

  String nameOf(String a) {
    if (isSelf(a)) return l10n.notificationsScreenYou;
    return cached(a) ?? fromChain[a.toLowerCase()] ?? shortAddr(a);
  }

  return (isSelf: isSelf, nameOf: nameOf);
}

bool _isAddress(String a) =>
    a.length == 42 && a.startsWith('0x') && RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(a);

/// The text a social popup quotes under its sentence:
/// the real comment, or the post's title / first line for a mention in a post
/// or a reaction on a post, FETCHED from where it is published. The wire
/// carries no text on purpose (spec: no free text, a rogue SSP could write
/// anything onto a lock screen), so the phone reads the item itself, signed
/// when the reader signs that channel. Null on a follow kind, a miss, a slow
/// host (3 s), a locked channel or a deleted comment: the sentence stands
/// alone, as before.
Future<String?> socialPreview(NotifItem item) async {
  if (!kSocialKinds.contains(item.kind) ||
      item.kind == NotifKind.followRequest ||
      item.kind == NotifKind.followApproved) {
    return null;
  }
  final e = item.event;
  final url = socialItemUrl(e);
  if (url.isEmpty) return null;
  try {
    if (socialItemIsComment(e)) {
      final r = await PublicOSChannels.getCommentByUrl(url)
          .timeout(const Duration(seconds: 3));
      final c = r.data;
      if (c == null || c.isDeleted) return null;
      return trimPreview(c.content);
    }
    final r = await PublicOSChannels.getPostByUrl(url)
        .timeout(const Duration(seconds: 3));
    final p = r.data;
    if (p == null) return null;
    return trimPreview(p.title.trim().isNotEmpty ? p.title : p.contentText);
  } catch (_) {
    return null;
  }
}

/// One line, whitespace collapsed, at most [max] characters with an ellipsis.
String? trimPreview(String? raw, {int max = 80}) {
  if (raw == null) return null;
  final one = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (one.isEmpty) return null;
  if (one.length <= max) return one;
  return '${one.substring(0, max - 1)}…';
}

/// `<sentence>: "<preview>"`, or the sentence alone.
String withSocialPreview(String sentence, String? preview) =>
    preview == null ? sentence : '$sentence: "$preview"';

/// The local-notification payload for an activity row: a social row opens
/// its post, a follow request the channel's request queue, an approval the
/// channel's feed (both carry the CHANNEL url as `item_url`), a money
/// row the wallet, anything else the activity feed. A social payload names
/// the account it is for, so another account's sign-in drops the tap.
String activityTapPayload(NotifItem item) {
  if (kSocialKinds.contains(item.kind)) {
    final url = socialItemUrl(item.event);
    return PublicOS.notificationPayload(socialTapType(item.kind), url);
  }
  return kWalletKinds.contains(item.kind) ? 'wallet' : 'activity';
}

/// The `onNotificationTapped` type for a social kind: `post` (the item's
/// permalink), `follow` (a request: the owner's channel settings on its
/// queue) or `channel` (an approval: the channel's feed).
String socialTapType(NotifKind kind) {
  switch (kind) {
    case NotifKind.followRequest:
      return 'follow';
    case NotifKind.followApproved:
      return 'channel';
    default:
      return 'post';
  }
}

/// Pop OS notifications for fresh SOCIAL rows (a decrypted push, or the
/// inbox pull's new items), through the same taxonomy as the feed: per-kind
/// toggles apply, newest first, at most [cap]. The id is the row's
/// `txHash:logIndex` hash, so a push and a later pull of the same item
/// collapse onto one notification even if both reach here.
Future<void> popSocialEvents(
  List<ActivityEvent> fresh, {
  required String selfAddr,
  int cap = 8,
}) async {
  if (fresh.isEmpty) return;
  final enabled = await loadEnabledNotifKinds();
  final sorted = [...fresh]..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  final items = buildNotifications(sorted, enabled)
      .where((i) => kSocialKinds.contains(i.kind))
      .take(cap)
      .toList();
  if (items.isEmpty) return;
  final l10n = await isolateLocalizations();
  // The actors get one chain lookup each when the contact cache misses.
  final names = await contactNameResolvers(
    selfAddr,
    l10n,
    lookup: items.map((i) => i.event.actor),
  );
  for (final item in items) {
    final body = withSocialPreview(
      notifSentence(
        item,
        l10n,
        isSelf: names.isSelf,
        nameOf: names.nameOf,
      ),
      await socialPreview(item),
    );
    final e = item.event;
    await PublicOSActivity.showActivityNotification(
      id: '${e.txHash}:${e.logIndex}'.hashCode & 0x7fffffff,
      title: 'PublicOS',
      body: body,
      payload: activityTapPayload(item),
    );
  }
}

const _cursorPrefix = 'social_inbox_cursor_';

/// Pull the home inbox past the stored cursor, store every item that is new
/// (idempotent on the notification id, so items the push already stored are
/// skipped) and advance the cursor. Returns the NEW rows only: the caller
/// pops those. [home] is the account's home SSP base URL; the caller
/// resolves it (`PublicOSSsp.homeForIsolate()`).
Future<List<ActivityEvent>> pullSocialInbox({
  required String account,
  required String home,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final key = '$_cursorPrefix${account.toLowerCase()}';
  final after = prefs.getInt(key) ?? 0;
  final page = await PublicOSPush.listNotifications(
    after: after,
    limit: 100,
    serverAddress: home,
  );
  final fresh = <ActivityEvent>[];
  for (final n in page.items) {
    final ev = ActivityEvent.social(n.toPushData());
    if (await PublicOSActivity.storeIfNew(ev)) fresh.add(ev);
  }
  if (page.next > after) await prefs.setInt(key, page.next);
  return fresh;
}

/// The inbox pull from the FOREGROUND app: on resume and when the
/// notifications screen opens, so
/// a push the OS dropped shows within seconds of coming back instead of at
/// the next 15-min tick. Behind the Social notifications switch, the same
/// pull the worker runs, the same popups for what is new. Returns how many
/// rows were new. Never throws.
Future<int> pullSocialInboxNow() async {
  try {
    if (!await PublicOSSettings.getSocialNotifications()) return 0;
    final me = PublicOS.myPublicosAddress;
    final home = await PublicOSSsp.homeForIsolate();
    if (me == null || home == null) return 0;
    final fresh = await pullSocialInbox(account: me, home: home);
    if (fresh.isNotEmpty) await popSocialEvents(fresh, selfAddr: me);
    return fresh.length;
  } catch (e) {
    debugPrint('[social] foreground pull failed: $e');
    return 0;
  }
}
