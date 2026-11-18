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
