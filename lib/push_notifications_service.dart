import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:publicos_core/publicos_core.dart';

import 'firebase_options.dart';
import 'social_push.dart';
import 'utils/notification_kinds.dart';
import 'utils/social_notifs.dart';

/// Background-isolate handler for incoming FCM push messages.
///
/// Runs in a separate Dart isolate when the app is killed/backgrounded and
/// FCM delivers a push. MUST be a top-level (or static) function, registered
/// via `FirebaseMessaging.onBackgroundMessage` in `main.dart` BEFORE
/// `runApp`.
///
/// **v1 strategy:** push is treated as a wake-up trigger. We re-initialize
/// Firebase per-isolate then run [PublicOS.executeBackgroundSync], which
/// re-initializes the full background isolate (secure storage → keys →
/// XMTP client) and scans for new messages since `bg_last_sync`. That scan
/// catches the just-pushed message + any others it missed. Trade-off: extra
/// XMTP round-trip per bg push vs. duplicating the heavy bg-isolate init
/// logic. Direct-decrypt path is a v2 followup.
///
/// Foreground handler in [PushNotificationsService.attach] takes the fast
/// direct path via `PublicOSPush.handleIncomingPush`.
@pragma('vm:entry-point')
Future<void> firebasePushBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  if (message.data['type'] == 'social') {
    await _socialPushInBackground(message.data);
    return;
  }
  debugPrint('[push/bg] received: topic=${message.data['topic']} '
      'len=${(message.data['encryptedMessage'] as String?)?.length ?? 0}');
  try {
    // Direct-decrypt: bring this fresh isolate to a ready state (creds → XMTP
    // client → DB → notif plugin, statics wired), then decode the payload
    // bytes in-isolate — no network scan. `handleIncomingPush` has its own
    // internal fallback render on a decrypt error, and the 15-min Workmanager
    // sweep is the periodic backstop for anything a single push misses.
    final ready = await PublicOS.ensureBackgroundIsolateReady();
    if (ready == null) {
      debugPrint('[push/bg] isolate not ready, falling back to sweep');
      await PublicOS.executeBackgroundSync();
      return;
    }
    await PublicOSPush.handleIncomingPush(message.data);
  } catch (e) {
    debugPrint('[push/bg] handler failed: $e');
  }
}

/// A social push (`{type: social, id, handle, blob}`)
/// while the app is closed. Android only in practice: on iOS the extension
/// renders it (no `content-available`, so this handler never wakes). The
/// chain isolate is enough — no XMTP client: open the blob with this device's
/// K_s, store the row (idempotent on the id), and pop it through the same
/// taxonomy as the feed. The 15-min inbox pull is the backstop.
Future<void> _socialPushInBackground(Map<String, dynamic> data) async {
  try {
    final ready = await PublicOSActivity.ensureChainIsolateReady();
    if (ready == null) return;
    final ev = await PublicOSPush.storeSocialPush(data);
    if (ev != null) {
      final me = PublicOS.myPublicosAddress ?? ready;
      await popSocialEvents([ev], selfAddr: me);
    }
    await PublicOS.database.close();
  } catch (e) {
    debugPrint('[push/bg] social handler failed: $e');
  }
}

/// Foreground/lifecycle wiring for FCM push notifications.
///
/// Single instance per app boot. Owns:
///   - `FirebaseMessaging.requestPermission` (OS-level prompt on first run)
///   - `FirebaseMessaging.onMessage` foreground listener (delegates to
///     [PublicOSPush.handleIncomingPush])
///   - `FirebaseMessaging.onTokenRefresh` listener (re-registers with the
///     notif server when FCM rotates the token)
///
/// Use [bootstrap] from post-XMTP boot paths to wire everything up in one
/// call.
class PushNotificationsService {
  static PushNotificationsService? _instance;
  static PushNotificationsService get instance =>
      _instance ??= PushNotificationsService._();
  PushNotificationsService._();

  bool _attached = false;

  /// Idempotent post-XMTP boot finalization. Both `AppInitializer._autoLogin`
  /// and `SelectAccountScreen._selectAccount` call this after `initXMTP()`.
  ///
  /// Gated on [PublicOSSettings.getPushNotifications] — if the user has
  /// push disabled, returns early (the 15-min Workmanager sweep still runs
  /// as the safety net for all users; see `app_initializer.dart` Stage 5).
  ///
  /// Sequence: attach listeners → request permission → fetch FCM token →
  /// register installation with notif server → subscribe to all topics +
  /// welcome topic. The network calls are fired in a background Future so
  /// boot isn't blocked on the notif server's response time.
  static Future<void> bootstrap() async {
    final enabled = await PublicOSSettings.getPushNotifications();
    if (!enabled) {
      debugPrint('[push] disabled by user setting, skipping bootstrap');
      return;
    }
    try {
      await instance.attach();
      final token = await instance.getCurrentToken();
      if (token == null) {
        debugPrint('[push] no FCM token, skipping registration');
        return;
      }
      // ignore: unawaited_futures
      Future(() async {
        await _registerMessages(token);
        // The social registration a little later, so the two never land in
        // the same second (the boot call is also the
        // home's ticket refresh and the gateway's expiry refresh).
        await Future.delayed(const Duration(seconds: 45));
        await SocialPushRegistration.register();
      });
    } catch (e, st) {
      debugPrint('[push] bootstrap failed (bg sweep still active): $e\n$st');
    }
  }

  /// The XMTP installation whose message pushes this process has registered
  /// (each XMTP key is its own installation). Null = none yet.
  static String? _messagesRegisteredFor;

  /// Register the loaded XMTP installation for message pushes and subscribe
  /// its conversations. Skipped when this installation is already done in
  /// this process (boot reaches here twice: the key-loaded hook, then
  /// [bootstrap]).
  static Future<void> _registerMessages(String token) async {
    try {
      final client = PublicOS.xmtpClient;
      if (client == null || PublicOS.clientXmtpInboxId == null) return;
      final installation = await client.getInstallationId();
      if (_messagesRegisteredFor == installation) return;
      _messagesRegisteredFor = installation;
      await PublicOSPush.registerWithNotifServer(fcmToken: token);
      await PublicOSPush.subscribeAllConversations();
    } catch (e, st) {
      _messagesRegisteredFor = null;
      debugPrint('[push] register+subscribe failed: $e\n$st');
    }
  }

  /// The push toggle went off and the installation was unregistered: the next
  /// [bootstrap] must register it again.
  static void forgetMessageRegistration() => _messagesRegisteredFor = null;

  /// An XMTP key just became the loaded one, from any door: boot, the
  /// keychain sheet, Manage inbox IDs, create fresh, restore a backup. Wired
  /// once in main.dart to [PublicOS.onXmtpClientReady], so no screen has to
  /// remember it. If only boot registered, a key loaded
  /// during a session (every new user's first key) would get no message pushes
  /// until the app was restarted.
  static Future<void> onXmtpKeyLoaded() async {
    try {
      if (!await PublicOSSettings.getPushNotifications()) return;
      await instance.attach();
      final token = await instance.getCurrentToken();
      if (token == null) {
        debugPrint('[push] key loaded, no FCM token, not registered');
        return;
      }
      await _registerMessages(token);
    } catch (e) {
      debugPrint('[push] registration after a key load failed: $e');
    }
  }

  /// Attach the foreground listeners + request OS permission. Idempotent —
  /// safe across account switches. Normally invoked via [bootstrap]; only
  /// call directly if you need the listeners attached without the
  /// register/subscribe flow.
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;

    try {
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      debugPrint('[push] permission: ${settings.authorizationStatus}');
    } catch (e) {
      debugPrint('[push] requestPermission failed: $e');
    }

    // Foreground: app open, client alive, fast direct-decrypt path.
    FirebaseMessaging.onMessage.listen((message) async {
      if (message.data['type'] == 'social') {
        await _socialPushInForeground(message.data);
        return;
      }
      debugPrint('[push/fg] received: topic=${message.data['topic']}');
      try {
        await PublicOSPush.handleIncomingPush(message.data);
      } catch (e) {
        debugPrint('[push/fg] handleIncomingPush failed: $e');
      }
    });

    // Notification tap while app is backgrounded (warm start). On Android the
    // tap on a flutter_local_notifications-rendered MessagingStyle routes via
    // its own `onDidReceiveNotificationResponse` → `PublicOS._onNotificationTapped`
    // path. On iOS the NSE renders the notif directly to UNUserNotificationCenter
    // bypassing flutter_local_notifications; firebase_messaging swizzles
    // UNUserNotificationCenter so the tap delivery still flows through here.
    FirebaseMessaging.onMessageOpenedApp.listen(_routeTap);

    // Cold-start tap: app was killed, user tapped the notification, iOS
    // launched the app. The launching message is available here once and
    // stays returnable across subsequent calls. Account selection may not
    // have happened yet — onNotificationTapped's handler routes via
    // pending-route if so.
    FirebaseMessaging.instance.getInitialMessage().then((message) {
      if (message != null) _routeTap(message);
    });

    // FCM token rotation — re-register so the notif server keeps delivering.
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
      debugPrint('[push] token refreshed: ${newToken.substring(0, 16)}...');
      try {
        await PublicOSPush.registerWithNotifServer(fcmToken: newToken);
      } catch (e) {
        debugPrint('[push] re-register on tokenRefresh failed: $e');
      }
    });
  }

  /// Route a tapped notification into PublicOS.onNotificationTapped so
  /// app_initializer's existing handler can navigate (or stash a pending
  /// route when the user hasn't selected an account yet).
  void _routeTap(RemoteMessage message) {
    if (message.data['type'] == 'social') {
      _routeSocialTap(message.data);
      return;
    }
    final topic = message.data['topic'] as String?;
    if (topic == null || topic.isEmpty) {
      debugPrint('[push/tap] no topic in payload, ignoring');
      return;
    }
    debugPrint('[push/tap] routing to conversation: $topic');
    PublicOS.onNotificationTapped?.call('message', topic);
  }

  /// A social push with the app open: store the row (idempotent on the id)
  /// and pop it like the background path does; the bell catches up on its
  /// next sweep.
  Future<void> _socialPushInForeground(Map<String, dynamic> data) async {
    try {
      final ev = await PublicOSPush.storeSocialPush(data);
      final me = PublicOS.myPublicosAddress;
      if (ev != null && me != null) await popSocialEvents([ev], selfAddr: me);
    } catch (e) {
      debugPrint('[push/fg] social push failed: $e');
    }
  }

  /// The tap on a social push: the payload is still the ciphertext (the OS
  /// renders what the extension or the local plugin showed), so open the blob
  /// here and route to the post.
  Future<void> _routeSocialTap(Map<String, dynamic> data) async {
    try {
      final fields = await PublicOSPush.openSocialPush(data);
      final url = fields?['item_url'] as String?;
      if (url == null || url.isEmpty) return;
      // A follow kind's item_url is the CHANNEL, not a post.
      final kind = socialKindOf('${fields?['kind'] ?? ''}');
      final type = kind == null ? 'post' : socialTapType(kind);
      debugPrint('[push/tap] routing to $type');
      PublicOS.onNotificationTapped?.call(type, url);
    } catch (e) {
      debugPrint('[push/tap] social tap failed: $e');
    }
  }

  /// Fetch the current FCM token. Call after [attach]. Returns null if the
  /// platform can't produce one.
  Future<String?> getCurrentToken() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('[push] getToken failed: $e');
      return null;
    }
  }
}
