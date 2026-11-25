import 'package:flutter/services.dart';

/// Opens this app's page in Android's system settings (App info), where the
/// user can allow background data and set battery use to unrestricted.
/// Hand-rolled, no plugin: the native handler is in MainActivity.kt on the
/// `com.publicos/app_system_settings` channel. Android only; returns false on
/// any failure (other platforms have no handler).
const MethodChannel _channel = MethodChannel('com.publicos/app_system_settings');

Future<bool> openAppSystemSettings() async {
  try {
    return await _channel.invokeMethod<bool>('open') ?? false;
  } catch (_) {
    return false;
  }
}

/// Opens the phone's security settings, where a screen lock is set. Android
/// only; false elsewhere.
Future<bool> openDeviceSecuritySettings() async {
  try {
    return await _channel.invokeMethod<bool>('openSecurity') ?? false;
  } catch (_) {
    return false;
  }
}

/// Asks Android to delete ALL of this app's data and end the process (the
/// same as Settings > Apps > Clear storage). On success this call never
/// returns. Android only; false elsewhere, and the caller falls back to
/// `PublicOSAuth.wipeLocalData`.
Future<bool> clearAppDataNatively() async {
  try {
    return await _channel.invokeMethod<bool>('clearAppData') ?? false;
  } catch (_) {
    return false;
  }
}
