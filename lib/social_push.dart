import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ios/ios_app_group.dart';
import 'utils/notification_kinds.dart';

/// The SECOND Firebase project, `your-social-firebase-project`: the sender behind the
/// social-push gateway (the token split). The XMTP relay
/// keeps the default app (`your-firebase-project`); this
/// project gives the phone a second, unrelated FCM token, so no database on
/// our side can join a social handle to an XMTP installation.
///
/// Values come from the project's `google-services.json` /
/// `GoogleService-Info.plist`. These are client
/// identifiers, not secrets: the default project's ship in the APK too.
class SocialFirebaseOptions {
  SocialFirebaseOptions._();
  static const projectId = 'your-social-firebase-project';
  static const senderId = '000000000000';
  static const androidAppId = '1:000000000000:android:0000000000000000000000';
  static const androidApiKey = 'YOUR_FIREBASE_API_KEY';
  static const iosAppId = '1:000000000000:ios:0000000000000000000000';
  static const iosApiKey = 'YOUR_FIREBASE_API_KEY';
}

/// The social FCM token, from native code.
///
/// `firebase_messaging` 16.x serves the DEFAULT Firebase app only (its own
/// source: "Messaging does not yet support multiple Firebase Apps"), so the
/// second sender's token is fetched behind a small platform channel:
/// Android initialises a named secondary `FirebaseApp` from these options and
/// asks its `FirebaseMessaging` component; iOS asks
/// `Messaging.retrieveFCMToken(forSenderID:)`, which needs only the sender
/// id and an APNs token already set. Delivery is unchanged: one messaging
/// service per package receives both senders, and iOS arrives through APNs.
///
/// Neither platform has a refresh callback for a secondary sender, so the
/// token is re-fetched at every boot registration (which is also the
/// ticket refresh, [SocialPushRegistration.register]).
class SocialPushToken {
  SocialPushToken._();
  static const _channel = MethodChannel('com.publicos/social_push');

  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static Future<String?> get() async {
    if (!supported) return null;
    try {
      final token = await _channel.invokeMethod<String>('getToken', {
        'projectId': SocialFirebaseOptions.projectId,
        'senderId': SocialFirebaseOptions.senderId,
        'appId': Platform.isAndroid
            ? SocialFirebaseOptions.androidAppId
            : SocialFirebaseOptions.iosAppId,
        'apiKey': Platform.isAndroid
            ? SocialFirebaseOptions.androidApiKey
            : SocialFirebaseOptions.iosApiKey,
      });
      if (token == null || token.isEmpty) return null;
      return token;
    } catch (e) {
      debugPrint('[social] getToken failed: $e');
      return null;
    }
  }
}

/// Registers this device for social pushes, and forgets it.
///
/// The flow (the blind gateway): PUT the official "deliver me here"
/// target at the HOME SSP with this device's keys (K_s + R_pub), which
/// answers the handle and a home-signed ticket naming no account; then bind
/// the social token to the handle at the gateway with an envelope signed by
/// the throwaway key R. Every boot repeats it: the home's ticket is the
/// 14-day paid-domain recheck, enforced by expiry at the gateway.
class SocialPushRegistration {
  SocialPushRegistration._();
  static const _prefToken = 'social_fcm_token';
  static const _prefHandle = 'social_handle';

  /// Best effort, never throws. Call a little after the XMTP subscribe so
  /// the two registrations don't land in the same second.
  static Future<void> register() async {
    if (!SocialPushToken.supported) return;
    try {
      if (!await PublicOSSettings.getPushNotifications()) return;
      final token = await SocialPushToken.get();
      if (token == null) {
        debugPrint('[social] no social token, skipping registration');
        return;
      }
      final socialOn = await PublicOSSettings.getSocialNotifications();
      final kinds = socialKindsMap(await loadEnabledNotifKinds());
      final target = await PublicOSPush.putNotifTarget(
        enabled: socialOn,
        kinds: kinds,
      );
      final ticket = target.ticket;
      if (ticket == null) {
        debugPrint('[social] home answered no ticket, skipping gateway');
        return;
      }
      final exp = await PublicOSPush.registerSocialHandle(
        handle: target.handle,
        socialToken: token,
        ticket: ticket,
        gateway: target.gateway,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefToken, token);
      await prefs.setString(_prefHandle, target.handle);
      // iOS: the extension opens blobs with K_s, so mirror it into the shared
      // keychain the way the XMTP DB key is mirrored.
      await IosAppGroup.mirrorSocialKey();
      debugPrint('[social] registered handle=${target.handle.substring(0, 8)}… '
          'exp=$exp');
    } catch (e) {
      // A lapsed domain answers 403 DOMAIN_NOT_PAID here: no push until the
      // next boot after the domain is paid. The inbox pull still runs.
      debugPrint('[social] registration failed: $e');
    }
  }

  /// Push switched off: drop this device's token at the gateway. The home's
  /// device row dies with its ticket (14 days). Best effort.
  static Future<void> unregister() async {
    if (!SocialPushToken.supported) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_prefToken);
      final handle = prefs.getString(_prefHandle);
      if (token == null || handle == null) return;
      await PublicOSPush.unregisterSocialHandle(
        handle: handle,
        socialToken: token,
      );
      await prefs.remove(_prefToken);
      await prefs.remove(_prefHandle);
    } catch (e) {
      debugPrint('[social] unregister failed: $e');
    }
  }
}
