import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:publicos_core/publicos_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zero_cached_image/zero_cached_image.dart';

/// iOS App Group plumbing for the Notification Service Extension.
///
/// The NSE is a separate process and can't reach data inside the main app
/// sandbox. To let it decrypt incoming XMTP pushes and render rich
/// notifications, four pieces of state must live in a shared App Group
/// container instead of the app-scope locations they default to:
///
/// - XMTP installation DB (SQLCipher) — relocated under
///   `<group>/Library/Application Support/xmtp_db/`
/// - drift contacts DB (`publicos.sqlite`) — relocated under
///   `<group>/Library/Application Support/publicos.sqlite`
/// - zero_cached_image avatar cache — relocated under
///   `<group>/Library/Application Support/zero_cached_image/`
/// - XMTP DB encryption key — mirrored into a shared-Keychain access group
///
/// On every successful XMTP client init the active identity (inboxId, wallet,
/// environment, dbDir, keychain key name) is written to
/// `<group>/active_xmtp.json` so the NSE can `Client.build()` against the
/// same DB without re-doing onboarding.
class IosAppGroup {
  static const String _tag = 'IosAppGroup';
  static const MethodChannel _channel = MethodChannel('com.publicos/app_group');
  static const String _migrationDoneKey = 'ios_app_group_migration_v1_done';
  static const String _xmtpDbSubdir = 'Library/Application Support/xmtp_db';
  static const String _driftDbRel = 'Library/Application Support/publicos.sqlite';
  static const String _zeroCacheRoot = 'Library/Application Support';
  static const String _activeManifest = 'active_xmtp.json';
  static const String _xmtpDbKeyPrefix = 'xmtp_db_key_';

  static String? _containerPath;
  static bool _ready = false;

  static bool get _isApplicable => !kIsWeb && Platform.isIOS;

  /// Resolve App Group container path, migrate legacy files, point the Core
  /// overrides at the new locations, and register XMTP-client lifecycle
  /// callbacks. Idempotent. No-op on non-iOS. Returns false if the App Group
  /// capability is missing — fall back to app-scope (NSE will silently not
  /// fire, server-fork placeholder remains as fallback).
  static Future<bool> setup() async {
    if (!_isApplicable) return false;
    if (_ready) return true;

    try {
      final String? path = await _channel.invokeMethod<String>('getContainerPath');
      if (path == null || path.isEmpty) {
        Log.w(_tag, 'App Group container nil — NSE will not fire. '
            'Verify capability + entitlement in Xcode.');
        return false;
      }
      _containerPath = path;

      final xmtpDbDir = p.join(path, _xmtpDbSubdir);
      final driftDbPath = p.join(path, _driftDbRel);
      final cacheRoot = p.join(path, _zeroCacheRoot);

      // Run the one-shot migration BEFORE pointing Core at the new locations,
      // so the first `AppDatabase()` construction finds an existing file.
      await _runMigrationOnce(
        xmtpDbDir: xmtpDbDir,
        driftDbPath: driftDbPath,
      );

      PublicOS.xmtpDbDirectory = xmtpDbDir;
      PublicOS.driftDbPath = driftDbPath;
      ZeroCacheManager.instance = ZeroCacheManager(cacheRootOverride: cacheRoot);

      PublicOS.onXmtpClientReady = _publishActiveIdentity;
      PublicOS.onXmtpClientCleared = _clearActiveIdentity;

      _ready = true;
      Log.i(_tag, 'App Group ready at $path');
      return true;
    } on PlatformException catch (e) {
      Log.e(_tag, 'AppGroupBridge unavailable: ${e.message}');
      return false;
    } catch (e, st) {
      Log.e(_tag, 'setup failed: $e\n$st');
      return false;
    }
  }

  /// Force-publish the current XMTP identity into the App Group. Useful from
  /// boot if the client was restored without going through
  /// [PublicOS.onXmtpClientReady] for any reason.
  static Future<void> publishActiveIdentityIfReady() async {
    if (!_ready) return;
    if (PublicOS.clientXmtpInboxId == null) return;
    await _publishActiveIdentityAsync();
  }

  // ---------------------------------------------------------------------------
  // Migration (one-shot)
  // ---------------------------------------------------------------------------

  static Future<void> _runMigrationOnce({
    required String xmtpDbDir,
    required String driftDbPath,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migrationDoneKey) ?? false) return;

    await _migrateXmtpDbs(targetDir: xmtpDbDir);
    await _migrateDriftDb(targetPath: driftDbPath);

    await prefs.setBool(_migrationDoneKey, true);
    Log.i(_tag, 'Migration v1 complete');
  }

  static Future<void> _migrateXmtpDbs({required String targetDir}) async {
    try {
      // XMTPiOS's default location on iOS is the documents directory.
      final docs = await getApplicationDocumentsDirectory();
      await Directory(targetDir).create(recursive: true);
      int count = 0;
      await for (final entity in docs.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        // Match `xmtp-{env}-{inboxId}.db3` and its .wal/.shm sidecars.
        if (!(name.startsWith('xmtp-') &&
            (name.endsWith('.db3') ||
             name.endsWith('.db3-wal') ||
             name.endsWith('.db3-shm') ||
             name.endsWith('.db3.wal') ||
             name.endsWith('.db3.shm')))) {
          continue;
        }
        final dst = File(p.join(targetDir, name));
        if (await dst.exists()) continue; // never clobber
        try {
          await entity.copy(dst.path);
          if (await dst.length() == await entity.length()) {
            await entity.delete();
            count++;
          }
        } catch (e) {
          Log.w(_tag, 'XMTP DB migration: copy $name failed: $e');
        }
      }
      Log.i(_tag, 'XMTP DB migration moved $count file(s)');
    } catch (e, st) {
      Log.e(_tag, 'XMTP DB migration failed: $e\n$st');
    }
  }

  static Future<void> _migrateDriftDb({required String targetPath}) async {
    try {
      final target = File(targetPath);
      if (await target.exists()) return;
      final src = File(p.join(
        (await getApplicationSupportDirectory()).path,
        'publicos.sqlite',
      ));
      if (!await src.exists()) return;
      await Directory(p.dirname(target.path)).create(recursive: true);
      await _moveOne(src, target);
      // Drift sidecars use the `-wal` / `-shm` suffix (no dot).
      for (final ext in const ['-wal', '-shm', '-journal']) {
        final s = File('${src.path}$ext');
        if (await s.exists()) {
          await _moveOne(s, File('${target.path}$ext'));
        }
      }
      Log.i(_tag, 'Drift DB migrated to App Group');
    } catch (e, st) {
      Log.e(_tag, 'Drift DB migration failed: $e\n$st');
    }
  }

  /// Copy → verify size → delete original. Falls back to copy + delete when
  /// the cross-volume rename trick fails (which is normal on iOS between the
  /// app sandbox and the App Group container — different mount points).
  static Future<void> _moveOne(File src, File dst) async {
    try {
      await src.rename(dst.path);
    } on FileSystemException {
      await src.copy(dst.path);
      if (await dst.length() == await src.length()) {
        await src.delete();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Social push key mirror
  // ---------------------------------------------------------------------------

  /// The extension opens a social push's blob with this device's K_s, under a
  /// FIXED name: the extension knows no session address. Written after every
  /// registration ([SocialPushRegistration.register]), so an account switch
  /// re-points it at the active session's key.
  static const String socialKsSharedName = 'social_ks_active';

  static Future<void> mirrorSocialKey() async {
    if (!_isApplicable) return;
    final session = PublicOS.sessionBlockchainAddress;
    if (session == null) return;
    try {
      final v = await PublicOS.secureStorage
          .read(key: PublicOSPush.socialKsStorageKey(session));
      if (v == null || v.isEmpty) return;
      await _channel.invokeMethod<bool>('writeSharedKeychainKey', {
        'key': socialKsSharedName,
        'value': v,
      });
    } catch (e) {
      Log.w(_tag, 'mirrorSocialKey failed: $e');
    }
  }

  static Future<void> clearSocialKey() async {
    if (!_isApplicable) return;
    try {
      await _channel.invokeMethod<bool>('deleteSharedKeychainKey', {
        'key': socialKsSharedName,
      });
    } catch (e) {
      Log.w(_tag, 'clearSocialKey failed: $e');
    }
  }

  // Active identity manifest + Keychain mirror
  // ---------------------------------------------------------------------------

  /// Sync wrapper for the [PublicOS.onXmtpClientReady] callback (which is
  /// synchronous). Kicks the async work off and forgets it — we don't want
  /// to block the XMTP init path.
  static void _publishActiveIdentity() {
    unawaited(_publishActiveIdentityAsync());
  }

  static Future<void> _publishActiveIdentityAsync() async {
    if (_containerPath == null) return;
    final accountAddr = PublicOS.myPublicosAddress;
    final walletAddr = PublicOS.clientXmtpAddress;
    final inboxId = PublicOS.clientXmtpInboxId;
    final dbKey = PublicOS.currentXmtpDbKey;
    if (accountAddr == null || walletAddr == null || inboxId == null || dbKey == null) {
      Log.w(_tag, 'publishActiveIdentity: state incomplete — skipping');
      return;
    }

    final keychainKey = '$_xmtpDbKeyPrefix${accountAddr}_${walletAddr.toLowerCase()}';

    // Mirror the DB encryption key into the shared-Keychain access group so
    // the NSE can read it. Mirrors as base64-encoded string under the same
    // service flutter_secure_storage uses on iOS.
    try {
      await _channel.invokeMethod<bool>('writeSharedKeychainKey', {
        'key': keychainKey,
        'value': base64Encode(dbKey),
      });
    } catch (e) {
      Log.w(_tag, 'mirrorKeychainKey failed: $e');
      // Fall through — write the manifest anyway; NSE will simply fail to
      // load the key and deliver the placeholder.
    }

    final manifest = <String, dynamic>{
      'inboxId': inboxId,
      'walletAddress': walletAddr,
      'environment': 'production',
      'dbDir': PublicOS.xmtpDbDirectory ?? '',
      'dbKeychainKey': keychainKey,
      'writtenAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };

    try {
      final file = File(p.join(_containerPath!, _activeManifest));
      await file.writeAsString(jsonEncode(manifest), flush: true);
      Log.d(_tag, 'active_xmtp.json published');
    } catch (e) {
      Log.e(_tag, 'failed to write active manifest: $e');
    }
  }

  static void _clearActiveIdentity() {
    unawaited(_clearActiveIdentityAsync());
  }

  static Future<void> _clearActiveIdentityAsync() async {
    if (_containerPath == null) return;
    try {
      final file = File(p.join(_containerPath!, _activeManifest));
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
