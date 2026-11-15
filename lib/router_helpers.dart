import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:publicos_client/app_routes.dart';
import 'package:publicos_client/router.dart';

/// Type-safe navigation helpers for the app.
///
/// Usage: `AppNav.toProfile(context, '0xAddr')` instead of
/// `Navigator.pushNamed(context, '/browser', arguments: {...})`.
class AppNav {
  AppNav._(); // Prevent instantiation

  /// Navigate to a contact's profile.
  ///
  /// Returns the `context.push` future, which completes when the profile
  /// route is popped — callers like create-org `await` it to refresh on
  /// return. Statement-position callers can ignore the future.
  static Future<void> toProfile(BuildContext context, String address) {
    return context.push('/publicosAddress/$address');
  }

  /// Navigate to a contact's custom tab (web or channel) by its record key.
  ///
  /// In-app callers pass the [record] they already hold so the Browser mounts
  /// the tab on frame 1 (carried via go_router `extra`) instead of flashing the
  /// profile while the key resolves. The URL stays canonical for shareable
  /// links; `extra` is a pure render optimization, absent on cold links.
  static void toTab(BuildContext context, String address, String key,
      {Record? record}) {
    context.push('/publicosAddress/$address/tab/$key', extra: record);
  }

  /// Navigate to a contact's app tab. In-app callers pass the [app] they hold
  /// so it mounts instantly via go_router `extra` (see [toTab]).
  ///
  /// (The chat-by-label helper was removed — it had no in-app callers. The
  /// durable `/publicosAddress/:address/chat/:label` route still resolves
  /// external/shareable links in the Browser.)
  static void toApp(BuildContext context, String address,
      {String? appName, AppBookmark? app}) {
    context.push(
      appName != null
          ? '/publicosAddress/$address/app/$appName'
          : '/publicosAddress/$address/app',
      extra: app,
    );
  }

  /// Navigate to a group conversation by topic.
  ///
  /// Returns the `context.push` future, which completes when the
  /// conversation route is popped — callers like create-group `await` it
  /// to refresh on return. Statement-position callers can ignore it.
  static Future<void> toConversation(BuildContext context, String topic) {
    return context.push('/conversationTopic/${Uri.encodeComponent(topic)}');
  }

  /// Navigate to the add_session flow.
  static void toAddSession(BuildContext context, String address) {
    context.push('/add_session/$address');
  }

  /// Navigate to the new_account flow (pre-filled address, user enters username).
  static void toNewAccount(BuildContext context, String address) {
    context.push('/new_account/$address');
  }

  /// Navigate to a chat by XMTP inbox ID — the direct pointer (always that
  /// exact inbox; dies if abandoned). For the rotation-surviving alias use
  /// [toChat].
  static void toInbox(BuildContext context, String inboxId) {
    context.push('/inboxId/$inboxId');
  }

  /// Smart navigation to a contact — picks the best route based on available identifiers.
  ///
  /// This replaces the common pattern of checking publicosAddress, then
  /// registered inbox ids, and building argument maps.
  ///
  /// [tab] defaults to profile. Set to [BrowserTab.chat] for messaging contexts.
  static void toContact(
    BuildContext context,
    Contact contact, {
    BrowserTab tab = BrowserTab.profile,
  }) {
    final address = contact.publicosAddress?.eip55With0x;
    final inboxId = contact.registeredInboxIDs?.firstOrNull?.inboxId;

    // Chat tab: route by inboxId (DMs). Groups are routed via toConversation
    // directly by callers that already have a topic.
    if (tab == BrowserTab.chat) {
      if (inboxId != null) {
        toInbox(context, inboxId);
      }
      return;
    }

    if (address != null &&
        address != '0x0000000000000000000000000000000000000000') {
      if (tab == BrowserTab.app) {
        toApp(context, address);
        return;
      }
      toProfile(context, address);
    } else if (inboxId != null) {
      toInbox(context, inboxId);
    }
  }

  /// Navigate to own profile.
  static void toMyProfile(BuildContext context) {
    final myContact = AppStateNotifier.currentMyContact;
    if (myContact?.publicosAddress != null &&
        myContact!.publicosAddress!.eip55With0x.isNotEmpty) {
      toProfile(context, myContact.publicosAddress!.eip55With0x);
    }
  }

  /// Pop the current route (go back).
  static void back(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }
}
