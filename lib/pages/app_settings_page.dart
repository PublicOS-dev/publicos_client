import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, Uint8List;
import 'package:publicos_core/publicos_core.dart';

import 'package:publicos_client/components/app_version_label.dart';
import 'package:publicos_client/components/glass_contact_icon.dart';
import 'package:publicos_client/router_helpers.dart';
import 'package:publicos_client/components/keychain/keychain_sheet.dart';
import 'package:publicos_client/components/onboarding/onboarding_flow.dart';
import 'package:publicos_client/components/nft_avatar_prefs.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/components/system_app_scaffold.dart';
import 'package:publicos_client/data/demo_contacts.dart';
import 'package:publicos_client/data/demo_feeds_data.dart';
import 'package:publicos_client/push_notifications_service.dart';
import 'package:publicos_client/utils/open_app_system_settings.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/providers/locale_provider.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';
import 'package:publicos_client/social_push.dart';

/// App Settings — notification toggles, session auto-login, blockchain
/// polling, XMTP info, export/import DB key, and the 10-tap-gated
/// Developer card (add test contacts, RSS/Bluesky lists, app bookmarks,
/// sync log, test sync, profile redeploy, DAO register, destructive ops).
class AppSettingsPage extends StatefulWidget {
  const AppSettingsPage({super.key});

  @override
  State<AppSettingsPage> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends State<AppSettingsPage> {
  // 10-tap gate on the XMTP card title
  int _xmtpTapCount = 0;

  /// Mirrors `KeychainSheet.kInboxPromptOffKey`, inverted for display: the
  /// stored setting means "never ask", the toggle reads "do offer". Same key,
  /// so ticking "don't ask again" inside the keychain dialog turns this off,
  /// and turning this back on makes the offer return.
  bool _offerInboxPrompt = true;
  bool _showDeveloperOptions = false;

  /// Which settings group is open — one at a time, like channel settings'
  /// drawers; null = all closed. Session-only. Twin of publicos_desktop
  /// `settings_pane`, where the first group is Appearance (desktop-only).
  String? _openGroup = 'language';

  // Loading flags
  bool _isLoadingData = true;
  bool _isReseedingDemo = false;
  bool _isResetting = false;
  bool _isRedeployingProfile = false;
  bool _isCreatingNewsList = false;
  bool _isCreatingBlueskyList = false;
  bool _isBookmarkingApps = false;
  bool _isRegisteringDAO = false;
  bool _isDeletingContacts = false;
  bool _isDeletingApps = false;
  bool _isDeletingMessages = false;
  bool _isClearingNotifs = false;

  // Settings state
  bool _liveNotifications = true;
  bool _pushNotifications = true;
  bool _chainNotifications = false;
  bool _autoLogin = false;
  int _pollingMinutes = 60;
  bool _nftSparkles = true;
  bool _nftShimmer = true;

  // keccak256("PUBLICOS_ROOT_ORG")
  static final _rootOrgTypeHash = Uint8List.fromList([
    0x05, 0x81, 0x0c, 0xe1, 0xac, 0xed, 0xa5, 0x00, //
    0x58, 0x59, 0x7c, 0x4c, 0x4d, 0x41, 0x89, 0x4b, //
    0x55, 0x4d, 0x4a, 0xec, 0xd8, 0x82, 0x30, 0x8d, //
    0xe6, 0xf5, 0xe6, 0x45, 0x4f, 0x3a, 0x32, 0xd8, //
  ]);

  // Developer gate for the "redeploy profile" and "register DAO" options.
  // Set this to your own session address to unlock the developer options in
  // your build.
  static const String _devAddress =
      '0x0000000000000000000000000000000000000000';

  @override
  void initState() {
    super.initState();
    _loadInboxPromptSetting();
    _loadAllData();
  }

  // ──────────────────────────────────────────────────────────────────────
  // Load
  // ──────────────────────────────────────────────────────────────────────

  Future<void> _loadAllData({bool silent = false}) async {
    if (!silent) setState(() => _isLoadingData = true);
    try {
      await _loadNotificationSettings();
      await _loadSessionSettings();
      await _loadPollingSettings();
      await _loadAvatarSettings();
    } catch (_) {}
    if (mounted) setState(() => _isLoadingData = false);
  }

  Future<void> _loadAvatarSettings() async {
    try {
      await NftAvatarPrefs.ensureLoaded();
      if (mounted) {
        setState(() {
          _nftSparkles = NftAvatarPrefs.sparkles;
          _nftShimmer = NftAvatarPrefs.shimmer;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadNotificationSettings() async {
    try {
      final live = await PublicOSSettings.getLiveNotifications();
      final push = await PublicOSSettings.getPushNotifications();
      final chain = await PublicOSSettings.getChainNotifications();
      if (mounted) {
        setState(() {
          _liveNotifications = live;
          _pushNotifications = push;
          _chainNotifications = chain;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _liveNotifications = true;
          _pushNotifications = true;
          _chainNotifications = false;
        });
      }
    }
  }

  Future<void> _loadSessionSettings() async {
    try {
      final val =
          await PublicOS.secureStorage.read(key: 'auto_login') ?? 'false';
      if (mounted) setState(() => _autoLogin = val == 'true');
    } catch (_) {}
  }

  Future<void> _loadPollingSettings() async {
    try {
      final minutes = await PublicOSSettings.getModulePollingMinutes();
      if (mounted) setState(() => _pollingMinutes = minutes);
    } catch (_) {}
  }

  // ──────────────────────────────────────────────────────────────────────
  // Setting mutations
  // ──────────────────────────────────────────────────────────────────────

  Future<void> _updateLiveNotifications(bool enabled) async {
    final l10n = context.l10n;
    try {
      final success = await PublicOSSettings.setLiveNotifications(enabled);
      if (success && mounted) {
        setState(() => _liveNotifications = enabled);
      } else if (mounted) {
        _snack(l10n.appSettingsPageFailedUpdateLive);
      }
    } catch (e) {
      if (mounted) _snack(localizedError(l10n, e));
    }
  }

  Future<void> _updatePushNotifications(bool enabled) async {
    final l10n = context.l10n;
    try {
      final success = await PublicOSSettings.setPushNotifications(enabled);
      if (!success) {
        if (mounted) _snack(l10n.appSettingsPageFailedUpdatePush);
        return;
      }
      if (mounted) setState(() => _pushNotifications = enabled);
      // Wire up or tear down the FCM registration to match the new setting.
      // Bootstrap is idempotent and gated internally on the saved setting,
      // so re-calling on flip is safe.
      if (enabled) {
        await PushNotificationsService.bootstrap();
      } else {
        await PublicOSPush.unregister();
        PushNotificationsService.forgetMessageRegistration();
        // The social token too (its own Firebase project, its own gateway
        // row).
        await SocialPushRegistration.unregister();
      }
    } catch (e) {
      if (mounted) _snack(localizedError(l10n, e));
    }
  }

  Future<void> _updateChainNotifications(bool enabled) async {
    final l10n = context.l10n;
    try {
      final success = await PublicOSSettings.setChainNotifications(enabled);
      if (success && mounted) {
        setState(() => _chainNotifications = enabled);
      } else if (mounted) {
        _snack(l10n.appSettingsPageFailedUpdateChain);
      }
    } catch (e) {
      if (mounted) _snack(localizedError(l10n, e));
    }
  }

  Future<void> _updateAutoLogin(bool enabled) async {
    final l10n = context.l10n;
    try {
      await PublicOS.secureStorage.write(
        key: 'auto_login',
        value: enabled ? 'true' : 'false',
      );
      if (mounted) setState(() => _autoLogin = enabled);
    } catch (e) {
      if (mounted) _snack(localizedError(l10n, e));
    }
  }

  Future<void> _updatePollingMinutes(int minutes) async {
    final l10n = context.l10n;
    try {
      final success = await PublicOSSettings.setModulePollingMinutes(minutes);
      if (success && mounted) {
        setState(() => _pollingMinutes = minutes);
      }
    } catch (e) {
      if (mounted) _snack(localizedError(l10n, e));
    }
  }

  Future<void> _updateNftSparkles(bool enabled) async {
    await NftAvatarPrefs.setSparkles(enabled);
    if (mounted) setState(() => _nftSparkles = enabled);
  }

  Future<void> _updateNftShimmer(bool enabled) async {
    await NftAvatarPrefs.setShimmer(enabled);
    if (mounted) setState(() => _nftShimmer = enabled);
  }

  Future<void> _reconnectRpc() async {
    final l10n = context.l10n;
    try {
      await PublicOSBsp.connectToAvailableRPC();
      if (mounted) _snack(l10n.appSettingsPageReconnectedRpc);
    } catch (e) {
      if (mounted) _snack(localizedError(l10n, e));
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  // Dev gate + helpers
  // ──────────────────────────────────────────────────────────────────────

  void _onXmtpTitleTap() {
    setState(() {
      _xmtpTapCount++;
      if (_xmtpTapCount >= 10 && !_showDeveloperOptions) {
        _showDeveloperOptions = true;
        _openGroup = 'developer';
      }
    });
  }

  bool get _isDeveloperAddress {
    final currentAddress =
        PublicOS.currentBlockchainPrivateKey?.address.eip55With0x;
    return currentAddress?.toLowerCase() == _devAddress.toLowerCase();
  }

  String _formatAddress(String? address) {
    if (address == null || address.isEmpty || address.length < 10) {
      return context.l10n.appSettingsPageInvalidAddress;
    }
    return '${address.substring(0, 6)}...${address.substring(address.length - 4)}';
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    _snack(context.l10n.appSettingsPageCopiedToClipboard(label));
  }

  // ──────────────────────────────────────────────────────────────────────
  // Demo channel / Bluesky list + app bookmark helpers
  // ──────────────────────────────────────────────────────────────────────

  /// Overwrite-by-name semantics for the demo lists: delete any existing
  /// list with [name], then create it fresh with [icon].
  Future<FeedList?> _recreateList(String name, String icon) async {
    final existing = await PublicOSFeedLists.getUserLists();
    for (final list in existing.where((l) => l.name == name)) {
      await PublicOSFeedLists.deleteList(list.id);
    }
    return PublicOSFeedLists.createList(name, icon: icon);
  }

  Future<void> _createDemoChannelList() async {
    if (_isCreatingNewsList) return;
    final l10n = context.l10n;
    setState(() => _isCreatingNewsList = true);
    try {
      // Feeds are a baked, live-validated set (see demo_feeds_data.dart), no
      // longer scraped from contact channel records — the demo accounts that
      // carried those are gone. Direct external RSS URLs; RssParser reads them
      // straight (no PublicOS feed server), so they carry no source-account
      // provenance.
      final newsList = await _recreateList('News', '📰');
      if (newsList == null) {
        if (mounted) _snack(l10n.appSettingsPageFailedCreateNewsList);
        return;
      }
      int successCount = 0;
      int failCount = 0;
      for (final feed in kDemoNewsFeeds) {
        try {
          final success = await PublicOSFeedLists.addFeedToList(
            newsList.id,
            feed.url,
            feed.title,
            null,
          );
          if (success) {
            successCount++;
          } else {
            failCount++;
          }
        } catch (_) {
          failCount++;
        }
      }
      if (mounted) {
        _snack(
          l10n.appSettingsPageCreatedNewsList(successCount) +
              (failCount > 0
                  ? l10n.appSettingsPageFailedSuffix(failCount)
                  : ''),
        );
      }
    } catch (e) {
      if (mounted) _snack(localizedError(l10n, e));
    } finally {
      if (mounted) setState(() => _isCreatingNewsList = false);
    }
  }

  Future<void> _createBlueskyListFromContacts() async {
    if (_isCreatingBlueskyList) return;
    final l10n = context.l10n;
    setState(() => _isCreatingBlueskyList = true);
    try {
      final contacts = await PublicOSContacts.getStoredContacts();
      final blueskyFeeds = <Map<String, dynamic>>[];
      for (final contact in contacts) {
        if (contact.records.isEmpty) continue;
        final rssRecords = contact.records
            .where((r) => r.routerSubtype == RouterSubtype.channel)
            .toList();
        final canonical =
            rssRecords.where((r) => r.key == 'bluesky').firstOrNull;
        final legacy = canonical == null
            ? rssRecords.where((r) {
                final name = r.metadata.keys.contains('name')
                    ? (r.metadata['name'] as String).toLowerCase()
                    : r.key.toLowerCase();
                return name.contains('bluesky');
              }).firstOrNull
            : null;
        final record = canonical ?? legacy;
        if (record != null) {
          final feedName = record.metadata.keys.contains('name')
              ? record.metadata['name'] as String
              : record.key;
          blueskyFeeds.add({
            'url': record.value,
            'title': feedName,
            'feedFoundAtAccountAddress':
                contact.publicosAddress?.eip55With0x,
          });
        }
      }
      if (blueskyFeeds.isEmpty) {
        if (mounted) _snack(l10n.appSettingsPageNoBlueskyFeeds);
        return;
      }
      final blueskyList = await _recreateList('bluesky', '🧿');
      if (blueskyList == null) {
        if (mounted) _snack(l10n.appSettingsPageFailedCreateBlueskyList);
        return;
      }
      int successCount = 0;
      int failCount = 0;
      for (final feed in blueskyFeeds) {
        try {
          final success = await PublicOSFeedLists.addFeedToList(
            blueskyList.id,
            feed['url'] as String,
            feed['title'] as String?,
            null,
            feedFoundAtAccountAddress:
                feed['feedFoundAtAccountAddress'] as String?,
          );
          if (success) {
            successCount++;
          } else {
            failCount++;
          }
        } catch (_) {
          failCount++;
        }
      }
      if (mounted) {
        _snack(
          l10n.appSettingsPageCreatedBlueskyList(successCount) +
              (failCount > 0
                  ? l10n.appSettingsPageFailedSuffix(failCount)
                  : ''),
        );
      }
    } catch (e) {
      if (mounted) _snack(localizedError(l10n, e));
    } finally {
      if (mounted) setState(() => _isCreatingBlueskyList = false);
    }
  }

  Future<void> _bookmarkAllContactApps() async {
    if (_isBookmarkingApps) return;
    final l10n = context.l10n;
    setState(() => _isBookmarkingApps = true);
    try {
      final contacts = await PublicOSContacts.getStoredContacts();
      int successCount = 0;
      int failCount = 0;
      int skippedCount = 0;
      for (final contact in contacts) {
        if (contact.publicosAddress == null) continue;
        try {
          final apps = await PublicOSAppRegistry.getAllAccountApps(
            contact.publicosAddress!,
          );
          if (apps == null || apps.isEmpty) continue;
          for (final app in apps) {
            try {
              final already = await PublicOSAppRegistry.isAppBookmarked(
                app.appName,
                contact.publicosAddress!,
              );
              if (already) {
                skippedCount++;
                continue;
              }
              final success = await PublicOSAppRegistry.bookmarkApp(app);
              if (success) {
                successCount++;
              } else {
                failCount++;
              }
            } catch (_) {
              failCount++;
            }
          }
        } catch (_) {}
      }
      if (mounted) {
        var message = l10n.appSettingsPageBookmarkedApps(successCount);
        if (skippedCount > 0) {
          message += l10n.appSettingsPageAlreadyBookmarkedSuffix(skippedCount);
        }
        if (failCount > 0) {
          message += l10n.appSettingsPageFailedSuffix(failCount);
        }
        _snack(message);
      }
    } catch (e) {
      if (mounted) _snack(localizedError(l10n, e));
    } finally {
      if (mounted) setState(() => _isBookmarkingApps = false);
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  // Profile redeploy + DAO register (dev address only)
  // ──────────────────────────────────────────────────────────────────────

  Future<void> _redeployJmslProfile() async {
    if (_isRedeployingProfile) return;
    final l10n = context.l10n;
    setState(() => _isRedeployingProfile = true);
    try {
      final records = ProfileTemplates.getProfileRecords('jmsl');
      final privateKey = PublicOS.currentBlockchainPrivateKey;
      if (privateKey == null) throw Exception('No private key available');

      int successCount = 0;
      int failCount = 0;
      for (final record in records) {
        try {
          final customTypeStr = record.subtype ?? '';
          final recordValueJson = jsonEncode(record.toChainValue());
          await Future.any([
            PublicOSBsp.recordManagerContract.setRecord(
              (
                target: EthereumAddress.fromHex(PublicOS.myPublicosAddress!),
                key: record.key,
                value: recordValueJson,
                expiration:
                    record.chainExpiration,
                recordType: BigInt.from(record.type.index),
                customType: customTypeStr,
              ),
              credentials: privateKey,
            ),
            Future.delayed(const Duration(seconds: 15))
                .then((_) => throw Exception('Timeout')),
          ]);
          successCount++;
        } catch (_) {
          failCount++;
        }
      }

      if (mounted) {
        _snack(
          l10n.appSettingsPageRedeployedRecords(successCount) +
              (failCount > 0
                  ? l10n.appSettingsPageFailedSuffix(failCount)
                  : ''),
        );
      }
    } catch (e) {
      if (mounted) {
        _snack(localizedError(l10n, e,
            fallback: l10n.appSettingsPageRedeployFailed));
      }
    } finally {
      if (mounted) setState(() => _isRedeployingProfile = false);
    }
  }

  Future<void> _registerPublicOSDAO() async {
    if (_isRegisteringDAO) return;
    final l10n = context.l10n;
    setState(() => _isRegisteringDAO = true);
    try {
      final registry = ModuleRegistry(
        address: PublicOSBsp.moduleRegistryAddress,
        client: PublicOS.web3Client,
        chainId: PublicOS.CHAIN_ID,
      );

      final existing = await Future.any([
        registry.getModuleAddress((moduleType: _rootOrgTypeHash)),
        Future.delayed(const Duration(seconds: 10))
            .then((_) => throw Exception('Timeout')),
      ]);

      final isRegistered =
          existing.eip55Without0x != '0000000000000000000000000000000000000000';

      Contact? daoContact;
      if (isRegistered) {
        try {
          daoContact = await PublicOSContacts.fetchContact(existing);
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() => _isRegisteringDAO = false);

      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => _RegisterDAODialog(
          existingAddress: isRegistered ? existing : null,
          existingContact: daoContact,
        ),
      );

      if (result == null || result.isEmpty) return;

      setState(() => _isRegisteringDAO = true);

      final privateKey = PublicOS.currentBlockchainPrivateKey;
      if (privateKey == null) throw Exception('No private key available');

      await Future.any([
        registry.registerOrUpdateModule(
          (
            moduleType: _rootOrgTypeHash,
            moduleAddress: EthereumAddress.fromHex(result),
          ),
          credentials: privateKey,
        ),
        Future.delayed(const Duration(seconds: 30))
            .then((_) => throw Exception('Timeout')),
      ]);

      if (mounted) {
        _snack(l10n.appSettingsPageDaoRegistered(
            '${result.substring(0, 10)}...'));
      }
    } catch (e) {
      if (mounted) _snack(localizedError(l10n, e));
    } finally {
      if (mounted) setState(() => _isRegisteringDAO = false);
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  // Background sync / destructive ops
  // ──────────────────────────────────────────────────────────────────────

  Future<void> _testBackgroundSyncNow() async {
    final l10n = context.l10n;
    _snack(l10n.appSettingsPageRunningSync);
    try {
      final result = await PublicOS.executeBackgroundSync();
      if (mounted) {
        _snack(
          result
              ? l10n.appSettingsPageSyncCompleted
              : l10n.appSettingsPageSyncFailed,
        );
      }
    } catch (e) {
      if (mounted) _snack(localizedError(l10n, e));
    }
  }

  Future<void> _showBackgroundSyncLog() async {
    final log = await PublicOS.getBackgroundSyncLog();
    if (!mounted) return;
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.l),
        backgroundColor: tokens.surfaceDeep,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: tokens.borderSubtle),
        ),
        title: Text(
          l10n.appSettingsPageSyncLogTitle,
          style: TextStyle(
              fontFamily: 'SpaceGrotesk',
            color: tokens.starkWhite,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: SingleChildScrollView(
          child: (log == null || log.isEmpty)
              ? Text(
                  l10n.appSettingsPageSyncLogEmpty,
                  style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                    color: tokens.textDim,
                    fontSize: 13,
                    height: 1.4,
                  ),
                )
              : Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: tokens.glassFill,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: tokens.borderSubtle),
                  ),
                  child: SelectableText(
                    log,
                    style: TextStyle(
                    fontFamily: 'monospace',
                      color: tokens.starkWhite,
                      fontSize: 11,
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              l10n.appSettingsPageClose,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',color: tokens.starkWhite),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmCompleteReset() async {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
        backgroundColor: tokens.surfaceDeep,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: tokens.fallbackAccent.withValues(alpha: 0.4)),
        ),
        title: Text(
          l10n.appSettingsPageCompleteResetTitle,
          style: TextStyle(
              fontFamily: 'SpaceGrotesk',
            color: tokens.fallbackAccent,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          l10n.appSettingsPageCompleteResetBody,
          style: TextStyle(
              fontFamily: 'SpaceGrotesk',
            color: tokens.textDim,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              l10n.dlgCancel,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',color: tokens.textDim),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              l10n.appSettingsPageDeleteAllDataButton,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                color: tokens.fallbackAccent,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) _performCompleteReset();
  }

  Future<void> _performCompleteReset() async {
    if (_isResetting) return;
    final l10n = context.l10n;
    setState(() => _isResetting = true);
    try {
      await PublicOS.clearAllDatabaseAndSecretsData();
      if (mounted) {
        _snack(l10n.appSettingsPageAllDataDeleted);
      }
    } catch (e) {
      if (mounted) {
        _snack(localizedError(l10n, e,
            fallback: l10n.appSettingsPageResetFailed));
      }
    } finally {
      if (mounted) setState(() => _isResetting = false);
    }
  }

  Future<void> _deleteAllContacts() async {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
        backgroundColor: tokens.surfaceDeep,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: tokens.borderSubtle),
        ),
        title: Text(
          l10n.appSettingsPageDeleteContactsTitle,
          style: TextStyle(
              fontFamily: 'SpaceGrotesk',
            color: tokens.starkWhite,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          l10n.appSettingsPageDeleteContactsBody,
          style: TextStyle(
              fontFamily: 'SpaceGrotesk',
            color: tokens.textDim,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              l10n.dlgCancel,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',color: tokens.textDim),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              l10n.appSettingsPageDeleteAll,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',color: tokens.fallbackAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || _isDeletingContacts) return;
    setState(() => _isDeletingContacts = true);
    try {
      final contacts = await PublicOSContacts.getStoredContacts();
      int count = 0;
      for (final contact in contacts) {
        try {
          await PublicOSContacts.removeContact(contact);
          count++;
        } catch (_) {}
      }
      if (mounted) _snack(l10n.appSettingsPageDeletedContacts(count));
    } catch (e) {
      if (mounted) _snack(localizedError(l10n, e));
    } finally {
      if (mounted) setState(() => _isDeletingContacts = false);
    }
  }

  Future<void> _deleteAllMessagesAndConversations() async {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
        backgroundColor: tokens.surfaceDeep,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: tokens.borderSubtle),
        ),
        title: Text(
          l10n.appSettingsPageDeleteMessagesTitle,
          style: TextStyle(
              fontFamily: 'SpaceGrotesk',
            color: tokens.starkWhite,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          l10n.appSettingsPageDeleteMessagesBody,
          style: TextStyle(
              fontFamily: 'SpaceGrotesk',
            color: tokens.textDim,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              l10n.dlgCancel,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',color: tokens.textDim),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              l10n.appSettingsPageDeleteAll,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',color: tokens.fallbackAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || _isDeletingMessages) return;
    setState(() => _isDeletingMessages = true);
    try {
      await PublicOS.clearAllMessagesAndConversations();
      if (mounted) _snack(l10n.appSettingsPageDeletedMessages);
    } catch (e) {
      if (mounted) _snack(localizedError(l10n, e));
    } finally {
      if (mounted) setState(() => _isDeletingMessages = false);
    }
  }

  Future<void> _deleteAllApps() async {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
        backgroundColor: tokens.surfaceDeep,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: tokens.borderSubtle),
        ),
        title: Text(
          l10n.appSettingsPageDeleteAppsTitle,
          style: TextStyle(
              fontFamily: 'SpaceGrotesk',
            color: tokens.starkWhite,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          l10n.appSettingsPageDeleteAppsBody,
          style: TextStyle(
              fontFamily: 'SpaceGrotesk',
            color: tokens.textDim,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              l10n.dlgCancel,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',color: tokens.textDim),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              l10n.appSettingsPageDeleteAll,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',color: tokens.fallbackAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || _isDeletingApps) return;
    setState(() => _isDeletingApps = true);
    try {
      final apps = await PublicOSAppRegistry.getBookmarkedApps();
      int count = 0;
      for (final app in apps) {
        try {
          await PublicOSAppRegistry.removeBookmark(
            app.appName,
            app.ownerAccountAddress,
          );
          count++;
        } catch (_) {}
      }
      if (mounted) _snack(l10n.appSettingsPageDeletedApps(count));
    } catch (e) {
      if (mounted) _snack(localizedError(l10n, e));
    } finally {
      if (mounted) setState(() => _isDeletingApps = false);
    }
  }

  Future<void> _clearChainNotifications() async {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
        backgroundColor: tokens.surfaceDeep,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: tokens.borderSubtle),
        ),
        title: Text(
          l10n.appSettingsPageClearChainTitle,
          style: TextStyle(
              fontFamily: 'SpaceGrotesk',
            color: tokens.starkWhite,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          l10n.appSettingsPageClearChainBody,
          style: TextStyle(
              fontFamily: 'SpaceGrotesk',
            color: tokens.textDim,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              l10n.dlgCancel,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',color: tokens.textDim),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              l10n.appSettingsPageClear,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',color: tokens.fallbackAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || _isClearingNotifs) return;
    setState(() => _isClearingNotifs = true);
    try {
      final deleted = await PublicOSActivity.clearStored();
      if (mounted) _snack(l10n.appSettingsPageClearedNotifs(deleted));
    } catch (e) {
      if (mounted) _snack(localizedError(l10n, e));
    } finally {
      if (mounted) setState(() => _isClearingNotifs = false);
    }
  }

  // ──────────────────────────────────────────────────────────────────────
  // DB key export / import dialogs
  // ──────────────────────────────────────────────────────────────────────

  void _showExportDbKeyWarning() {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
        backgroundColor: tokens.surfaceDeep,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: tokens.fallbackAccent.withValues(alpha: 0.4)),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: tokens.fallbackAccent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.shield_outlined,
                color: tokens.fallbackAccent,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.appSettingsPageExportDbKeyTitle,
                style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                  color: tokens.starkWhite,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          l10n.appSettingsPageExportDbKeyBody,
          style: TextStyle(
              fontFamily: 'SpaceGrotesk',
            color: tokens.textDim,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              l10n.dlgCancel,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',color: tokens.textDim),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _showDbKeyExportDialog();
            },
            child: Text(
              l10n.appSettingsPageIUnderstand,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                color: tokens.fallbackAccent,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showDbKeyExportDialog() {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    final rawKey = PublicOS.currentXmtpDbKey;
    final keyB64 = rawKey != null ? base64Encode(rawKey) : null;
    final keyLabel =
        PublicOS.currentXmtpKeyLabel ?? l10n.appSettingsPageNoneLower;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.m),
        backgroundColor: tokens.surfaceDeep,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: tokens.borderSubtle),
        ),
        title: Text(
          l10n.appSettingsPageDbKeyTitle,
          style: TextStyle(
              fontFamily: 'SpaceGrotesk',
            color: tokens.starkWhite,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.appSettingsPageActiveXmtpKey(keyLabel),
                style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                  color: tokens.textDim,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),
              if (keyB64 == null)
                Text(
                  l10n.appSettingsPageNoDbKey,
                  style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                    color: tokens.fallbackAccent,
                    fontSize: 13,
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: tokens.glassFill,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: tokens.borderSubtle),
                  ),
                  child: SelectableText(
                    keyB64,
                    style: TextStyle(
                    fontFamily: 'monospace',
                      color: tokens.starkWhite,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          if (keyB64 != null)
            TextButton(
              onPressed: () {
                _copyToClipboard(keyB64, l10n.appSettingsPageCopyLabelDbKey);
              },
              child: Text(
                l10n.appSettingsPageCopy,
                style: TextStyle(
              fontFamily: 'SpaceGrotesk',color: tokens.connectedAccent),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              l10n.appSettingsPageClose,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',color: tokens.textDim),
            ),
          ),
        ],
      ),
    );
  }

  void _showImportDbKeyDialog() {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    final keyCtrl = TextEditingController();
    // Lift state out of the StatefulBuilder builder so it survives rebuilds.
    bool isImporting = false;
    String? errorText;
    showDialog(
      context: context,
      builder: (_) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return AlertDialog(
              constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.m),
              backgroundColor: tokens.surfaceDeep,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: tokens.borderSubtle),
              ),
              title: Text(
                l10n.appSettingsPageImportDbKeyTitle,
                style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                  color: tokens.starkWhite,
                  fontWeight: FontWeight.w800,
                ),
              ),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.appSettingsPageImportDbKeyBody,
                      style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                        color: tokens.textDim,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _GlassField(
                      tokens: tokens,
                      controller: keyCtrl,
                      label: l10n.appSettingsPageBase64KeyLabel,
                      errorText: errorText,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isImporting ? null : () => Navigator.pop(context),
                  child: Text(
                    l10n.dlgCancel,
                    style: TextStyle(
              fontFamily: 'SpaceGrotesk',color: tokens.textDim),
                  ),
                ),
                TextButton(
                  onPressed: isImporting
                      ? null
                      : () async {
                          final text = keyCtrl.text.trim();
                          if (text.isEmpty) {
                            setModalState(() =>
                                errorText = l10n.appSettingsPagePasteKeyError);
                            return;
                          }
                          try {
                            // Validate it's decodable base64 before sending.
                            base64Decode(text);
                            setModalState(() {
                              isImporting = true;
                              errorText = null;
                            });
                            final navigator = Navigator.of(ctx);
                            final ok =
                                await PublicOSKeychain.importXmtpDbKey(text);
                            if (!mounted) return;
                            if (ok) {
                              navigator.pop();
                              _snack(l10n.appSettingsPageDbKeyImported);
                            } else {
                              setModalState(() {
                                isImporting = false;
                                errorText = l10n.appSettingsPageImportFailed;
                              });
                            }
                          } catch (e) {
                            setModalState(() {
                              isImporting = false;
                              errorText = localizedError(l10n, e,
                                  fallback: l10n.appSettingsPageInvalidKey);
                            });
                          }
                        },
                  child: Text(
                    isImporting
                        ? l10n.appSettingsPageImportingButton
                        : l10n.appSettingsPageImportButton,
                    style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                      color: tokens.connectedAccent,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ──────────────────────────────────────────────────────────────────────
  // Build
  // ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return SystemAppScaffold(
      title: context.l10n.appSettingsPageSettingsTitle,
      icon: Icons.settings_rounded,
      asset: 'assets/system_apps/settings.png',
      pinHeader: true,
      builder: (context, scrollController, tokens) {
        return Stack(
          children: [
            if (!_isLoadingData)
              RefreshIndicator(
                onRefresh: () => _loadAllData(silent: true),
                color: tokens.starkWhite,
                backgroundColor: tokens.surfaceElevated,
                edgeOffset:
                    MediaQuery.of(context).padding.top + kToolbarHeight,
                child: _buildLoaded(scrollController, tokens),
              ),
            if (_isLoadingData)
              const Positioned(
                right: 16,
                bottom: 16,
                child: SafeArea(
                  child: PhigitalLoadingWidget(size: 28, showShadows: false),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildLoaded(ScrollController c, GlassTokens tokens) {
    return ListView(
      controller: c,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      children: [
        SizedBox(height: kToolbarHeight + 60),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _buildLanguageSection(tokens),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _buildNotificationsSection(tokens),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _buildSessionSection(tokens),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _buildBlockchainSection(tokens),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _buildAvatarSection(tokens),
        ),
        // iOS shows no mature profiles for now (browser.dart mature gate),
        // so there is nothing to list here.
        if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _group(
            tokens,
            id: 'mature',
            icon: Icons.visibility_outlined,
            title: context.l10n.settingsMatureProfilesTitle,
            children: const [_MatureProfilesList()],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _buildXmtpSection(tokens),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _buildHelpSection(tokens),
        ),
        if (_showDeveloperOptions)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _buildDeveloperSection(tokens),
          ),
        const SizedBox(height: 72),
      ],
    );
  }

  // ── Cards ────────────────────────────────────────────────────────────

  /// Language picker — the first surface converted to `context.l10n`. The
  /// choices feed [LocaleProvider] (SharedPreferences `app_locale`): "System
  /// default" clears the override (follow device → English fallback), English /
  /// Español set an explicit override. Endonyms ("English"/"Español") stay
  /// literal — language names are shown in their own language by convention.
  Widget _buildLanguageSection(GlassTokens tokens) {
    final l10n = context.l10n;
    final currentCode = LocaleProvider.instance?.locale?.languageCode; // null => system
    return _group(
      tokens,
      id: 'language',
      icon: Icons.language_rounded,
      title: l10n.settingsLanguageTitle,
      children: [
        Text(
          l10n.settingsLanguageSubtitle,
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            color: tokens.textDim,
            fontSize: 11,
            fontWeight: FontWeight.w400,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _choiceChip(
              tokens,
              l10n.settingsLanguageSystemDefault,
              currentCode == null,
              () => _setLocale(null),
            ),
            _choiceChip(
              tokens,
              'English',
              currentCode == 'en',
              () => _setLocale('en'),
            ),
            _choiceChip(
              tokens,
              'Español',
              currentCode == 'es',
              () => _setLocale('es'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _setLocale(String? code) async {
    final lp = LocaleProvider.instance;
    if (lp == null) return;
    await lp.setLocale(code == null ? null : Locale(code));
    if (mounted) setState(() {});
  }

  Widget _buildNotificationsSection(GlassTokens tokens) {
    final l10n = context.l10n;
    return _group(
      tokens,
      id: 'notifications',
      icon: Icons.notifications_outlined,
      title: l10n.appSettingsPageNotificationsTitle,
      children: [
        _toggleRow(
          tokens,
          title: l10n.appSettingsPageLiveNotificationsTitle,
          subtitle: l10n.appSettingsPageLiveNotificationsSubtitle,
          value: _liveNotifications,
          onChanged: _updateLiveNotifications,
        ),
        const SizedBox(height: 6),
        _toggleRow(
          tokens,
          title: l10n.appSettingsPagePushNotificationsTitle,
          subtitle: l10n.appSettingsPagePushNotificationsSubtitle,
          value: _pushNotifications,
          onChanged: _updatePushNotifications,
        ),
        const SizedBox(height: 6),
        _toggleRow(
          tokens,
          title: l10n.appSettingsPageChainNotificationsTitle,
          subtitle: l10n.appSettingsPageChainNotificationsSubtitle,
          value: _chainNotifications,
          onChanged: _updateChainNotifications,
        ),
        // Android only: with background data off or battery restricted, a
        // push arrives but the app has no network to read it, so nothing
        // rings. Point the user at the two
        // switches; they live on the app's page in the system settings.
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) ...[
          const SizedBox(height: 14),
          Text(
            l10n.appSettingsPageNotifsNotArrivingDesc,
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              color: tokens.textDim,
              fontSize: 11,
              fontWeight: FontWeight.w400,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 14),
          SystemAppActionButton(
            label: l10n.appSettingsPageOpenSystemSettingsButton,
            icon: Icons.settings_outlined,
            onTap: openAppSystemSettings,
          ),
        ],
      ],
    );
  }

  Widget _buildSessionSection(GlassTokens tokens) {
    final l10n = context.l10n;
    return _group(
      tokens,
      id: 'session',
      icon: Icons.login_rounded,
      title: l10n.appSettingsPageSessionTitle,
      children: [
        _toggleRow(
          tokens,
          title: l10n.appSettingsPageAutoLoginTitle,
          subtitle: l10n.appSettingsPageAutoLoginSubtitle,
          value: _autoLogin,
          onChanged: _updateAutoLogin,
        ),
      ],
    );
  }

  Widget _buildBlockchainSection(GlassTokens tokens) {
    final l10n = context.l10n;
    return _group(
      tokens,
      id: 'blockchain',
      icon: Icons.link_rounded,
      title: l10n.appSettingsPageBlockchainTitle,
      children: [
        _tile(
          tokens,
          child: Column(
            children: [
              _kvRow(tokens, l10n.appSettingsPageChainIdLabel,
                  '${PublicOS.CHAIN_ID}'),
              const SizedBox(height: 8),
              _kvRow(tokens, l10n.appSettingsPageRpcLabel,
                  _truncateUrl(PublicOS.activeRpcUrl)),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _miniLabel(tokens, l10n.appSettingsPagePollingRateLabel),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: const [15, 30, 60, 120, 360, 1440].map((m) {
            final active = m == _pollingMinutes;
            return _pollingChip(tokens, m, active, _updatePollingMinutes);
          }).toList(),
        ),
        const SizedBox(height: 14),
        SystemAppActionButton(
          label: l10n.appSettingsPageReconnectButton,
          icon: Icons.refresh_rounded,
          onTap: _reconnectRpc,
        ),
      ],
    );
  }

  Widget _buildAvatarSection(GlassTokens tokens) {
    final l10n = context.l10n;
    return _group(
      tokens,
      id: 'avatars',
      icon: Icons.auto_awesome,
      title: l10n.appSettingsPageAvatarTitle,
      children: [
        Text(
          l10n.appSettingsPageAvatarDesc,
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            color: tokens.textDim,
            fontSize: 11,
            fontWeight: FontWeight.w400,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 10),
        _toggleRow(
          tokens,
          title: l10n.appSettingsPageSparklesTitle,
          subtitle: l10n.appSettingsPageSparklesSubtitle,
          value: _nftSparkles,
          onChanged: _updateNftSparkles,
        ),
        const SizedBox(height: 6),
        _toggleRow(
          tokens,
          title: l10n.appSettingsPageShimmerTitle,
          subtitle: l10n.appSettingsPageShimmerSubtitle,
          value: _nftShimmer,
          onChanged: _updateNftShimmer,
        ),
      ],
    );
  }

  Widget _buildHelpSection(GlassTokens tokens) {
    final l10n = context.l10n;
    return _group(
      tokens,
      id: 'help',
      icon: Icons.help_outline,
      title: l10n.appSettingsPageHelpTitle,
      children: [
        Text(
          l10n.appSettingsPageHelpOnboardingDesc,
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            color: tokens.textDim,
            fontSize: 11,
            fontWeight: FontWeight.w400,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 14),
        SystemAppActionButton(
          label: l10n.appSettingsPageWatchOnboardingButton,
          icon: Icons.play_circle_outline,
          onTap: _watchOnboarding,
        ),
        // Visible demo tool: build a "News" list from a baked set of live RSS
        // feeds (demo_feeds_data.dart). Kept out of the developer-options gate
        // below so it's always available as reading material.
        const SizedBox(height: 14),
        Text(
          l10n.appSettingsPageDemoNewsDesc,
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            color: tokens.textDim,
            fontSize: 11,
            fontWeight: FontWeight.w400,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 14),
        SystemAppActionButton(
          label: _isCreatingNewsList
              ? l10n.appSettingsPageCreatingButton
              : l10n.appSettingsPageCreateDemoChannelButton,
          icon: Icons.rss_feed_rounded,
          onTap: _isCreatingNewsList ? null : _createDemoChannelList,
        ),
        // Remaining demo/dev seeding tools are gated behind the developer-options
        // unlock (tap the XMTP area 10x). Normal users see only "Watch
        // onboarding" + the News list above; onboarding remains the intended
        // seeding path.
        if (_showDeveloperOptions) ...[
          const SizedBox(height: 14),
          Text(
            l10n.appSettingsPageReseedDemoDesc,
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              color: tokens.textDim,
              fontSize: 11,
              fontWeight: FontWeight.w400,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 14),
          SystemAppActionButton(
            label: _isReseedingDemo
                ? l10n.appSettingsPageReseedingButton
                : l10n.appSettingsPageReseedDemoButton,
            icon: Icons.refresh,
            onTap: _isReseedingDemo ? null : _reseedDemoContacts,
          ),
          const SizedBox(height: 14),
          Text(
            l10n.appSettingsPageDemoFeedsDesc,
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              color: tokens.textDim,
              fontSize: 11,
              fontWeight: FontWeight.w400,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 14),
          SystemAppActionButton(
            label: _isCreatingBlueskyList
                ? l10n.appSettingsPageCreatingButton
                : l10n.appSettingsPageCreateDemoBlueskyButton,
            icon: Icons.cloud_outlined,
            onTap: _isCreatingBlueskyList ? null : _createBlueskyListFromContacts,
          ),
          const SizedBox(height: 14),
          SystemAppActionButton(
            label: _isBookmarkingApps
                ? l10n.appSettingsPageBookmarkingButton
                : l10n.appSettingsPageCreateDemoBookmarksButton,
            icon: Icons.apps_rounded,
            onTap: _isBookmarkingApps ? null : _bookmarkAllContactApps,
          ),
        ],
        const SizedBox(height: 16),
        const Align(
          alignment: Alignment.centerRight,
          child: AppVersionLabel(),
        ),
      ],
    );
  }

  /// Replay the onboarding flow as a pushed route. Preview mode means it won't
  /// touch the `onboarding_completed` flag and ends on "DONE" → pops back here.
  void _watchOnboarding() {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (ctx) => OnboardingFlow(
          previewMode: true,
          onComplete: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
  }

  /// Force-rerun the baked-demo-contact seed (bypasses the per-account
  /// one-shot flag). The seed itself is best-effort and never throws.
  Future<void> _reseedDemoContacts() async {
    final l10n = context.l10n;
    setState(() => _isReseedingDemo = true);
    try {
      await seedDemoContactsIfNeeded(force: true);
      if (!mounted) return;
      _snack(l10n.appSettingsPageDemoContactsReseeded);
    } finally {
      if (mounted) setState(() => _isReseedingDemo = false);
    }
  }

  Future<void> _loadInboxPromptSetting() async {
    try {
      final rec =
          await PublicOSSettings.getSetting(KeychainSheet.kInboxPromptOffKey);
      if (!mounted) return;
      setState(() => _offerInboxPrompt = rec?.value != 'true');
    } catch (_) {
      // Unreadable — leave the default (offer on), matching the keychain's
      // own fall-through behaviour.
    }
  }

  Future<void> _updateInboxPrompt(bool offer) async {
    setState(() => _offerInboxPrompt = offer);
    try {
      await PublicOSSettings.setSetting(
        KeychainSheet.kInboxPromptOffKey,
        Record.asSettings(
          key: KeychainSheet.kInboxPromptOffKey,
          // Stored inverted: the key means "never ask".
          value: (!offer).toString(),
          isSystem: true,
          isExpired: false,
        ),
      );
    } catch (_) {
      // Non-fatal; the toggle re-reads on next open.
    }
  }

  Widget _buildXmtpSection(GlassTokens tokens) {
    final l10n = context.l10n;
    final xmtpAddress = PublicOS.clientXmtpAddress;
    final inboxId = PublicOS.clientXmtpInboxId;
    final keyLabel = PublicOS.currentXmtpKeyLabel;
    final connected = xmtpAddress != null;

    return _group(
      tokens,
      id: 'xmtp',
      icon: Icons.forum_outlined,
      title: 'XMTP',
      trailing: connected
          ? _pillBadge(tokens, l10n.appSettingsPageConnectedBadge,
              tokens.connectedAccent)
          : null,
      // The hidden 10-tap developer unlock rides the header tap.
      onHeaderTap: _onXmtpTitleTap,
      children: [
        _tile(
          tokens,
          child: Column(
            children: [
              _kvRow(
                tokens,
                l10n.appSettingsPageAddressLabel,
                connected
                    ? _formatAddress(xmtpAddress)
                    : l10n.appSettingsPageNotInitialized,
                copyable: connected ? xmtpAddress : null,
                onCopy: (v) => _copyToClipboard(
                    v, l10n.appSettingsPageCopyLabelXmtpAddress),
              ),
              const SizedBox(height: 8),
              _kvRow(
                tokens,
                l10n.appSettingsPageInboxIdLabel,
                inboxId != null
                    ? _formatAddress(inboxId)
                    : l10n.appSettingsPageNotInitialized,
                copyable: inboxId,
                onCopy: (v) =>
                    _copyToClipboard(v, l10n.appSettingsPageInboxIdLabel),
              ),
              const SizedBox(height: 8),
              _kvRow(tokens, l10n.appSettingsPageActiveKeyLabel,
                  keyLabel ?? l10n.appSettingsPageNone),
            ],
          ),
        ),
        const SizedBox(height: 6),
        _toggleRow(
          tokens,
          title: l10n.appSettingsPageInboxPromptTitle,
          subtitle: l10n.appSettingsPageInboxPromptSubtitle,
          value: _offerInboxPrompt,
          onChanged: _updateInboxPrompt,
        ),
        // HIDDEN: the DB key export/import UI is hidden.
        // Handlers (_showExportDbKeyWarning/_showImportDbKeyDialog) kept intact;
        // uncomment this block to re-enable.
        /*
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: SystemAppActionButton(
                label: 'EXPORT',
                icon: Icons.upload_rounded,
                onTap: _showExportDbKeyWarning,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SystemAppActionButton(
                label: 'IMPORT',
                icon: Icons.download_rounded,
                onTap: _showImportDbKeyDialog,
              ),
            ),
          ],
        ),
        */
      ],
    );
  }

  Widget _buildDeveloperSection(GlassTokens tokens) {
    final l10n = context.l10n;
    return _group(
      tokens,
      id: 'developer',
      icon: Icons.bug_report_outlined,
      title: l10n.appSettingsPageDeveloperTitle,
      // The orange UNLOCKED pill marks the danger zone; the glyph stays grey
      // like every other group header.
      trailing: _pillBadge(tokens, l10n.appSettingsPageUnlockedBadge,
          tokens.fallbackAccent),
      children: [
        Text(
          l10n.appSettingsPageUtilitiesLabel,
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            color: tokens.textDim,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _devChip(
              tokens,
              Icons.bug_report_outlined,
              l10n.appSettingsPageSyncLogChip,
              loading: false,
              onTap: _showBackgroundSyncLog,
            ),
            _devChip(
              tokens,
              Icons.play_arrow_rounded,
              l10n.appSettingsPageTestSyncChip,
              loading: false,
              onTap: _testBackgroundSyncNow,
            ),
            if (_isDeveloperAddress) ...[
              _devChip(
                tokens,
                Icons.refresh_rounded,
                l10n.appSettingsPageRedeployChip,
                loading: _isRedeployingProfile,
                onTap: _isRedeployingProfile ? null : _redeployJmslProfile,
              ),
              _devChip(
                tokens,
                Icons.account_balance_rounded,
                l10n.appSettingsPageRegisterDaoChip,
                loading: _isRegisteringDAO,
                onTap: _isRegisteringDAO ? null : _registerPublicOSDAO,
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        Text(
          l10n.appSettingsPageDestructiveLabel,
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            color: tokens.fallbackAccent,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        _destructiveButton(
          tokens,
          icon: Icons.people_outline_rounded,
          label: _isDeletingContacts
              ? l10n.appSettingsPageDeletingButton
              : l10n.appSettingsPageDeleteAllContactsButton,
          onTap: _isDeletingContacts ? null : _deleteAllContacts,
        ),
        const SizedBox(height: 8),
        _destructiveButton(
          tokens,
          icon: Icons.forum_outlined,
          label: _isDeletingMessages
              ? l10n.appSettingsPageDeletingButton
              : l10n.appSettingsPageDeleteAllMessagesButton,
          onTap: _isDeletingMessages
              ? null
              : _deleteAllMessagesAndConversations,
        ),
        const SizedBox(height: 8),
        _destructiveButton(
          tokens,
          icon: Icons.apps_rounded,
          label: _isDeletingApps
              ? l10n.appSettingsPageDeletingButton
              : l10n.appSettingsPageDeleteAllAppsButton,
          onTap: _isDeletingApps ? null : _deleteAllApps,
        ),
        const SizedBox(height: 8),
        _destructiveButton(
          tokens,
          icon: Icons.notifications_off_rounded,
          label: _isClearingNotifs
              ? l10n.appSettingsPageClearingButton
              : l10n.appSettingsPageClearChainNotificationsButton,
          onTap: _isClearingNotifs ? null : _clearChainNotifications,
        ),
        const SizedBox(height: 8),
        _destructiveButton(
          tokens,
          icon: Icons.delete_forever_rounded,
          label: _isResetting
              ? l10n.appSettingsPageResettingButton
              : l10n.appSettingsPageResetAllDataButton,
          onTap: _isResetting ? null : _confirmCompleteReset,
        ),
      ],
    );
  }

  // ── Leaf helpers ─────────────────────────────────────────────────────

  Widget _miniLabel(GlassTokens tokens, String text, {Color? color}) {
    return Text(
      text,
      style: TextStyle(
        fontFamily: 'SpaceGrotesk',
        color: color ?? tokens.textDim,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.2,
      ),
    );
  }

  /// Collapsible settings group.
  /// Borrows `channel_settings_page`'s accordion drawers: one group open at a
  /// time, the whole header row toggles, the chevron turns 90°, the first group
  /// starts open. Shell deltas: no divider line (borderless), and the header's
  /// glyphs brighten on hover or while open, the way a rail row does.
  Widget _group(
    GlassTokens tokens, {
    required String id,
    required IconData icon,
    required String title,
    Widget? trailing,
    VoidCallback? onHeaderTap,
    required List<Widget> children,
  }) {
    final open = _openGroup == id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GroupHeader(
          icon: icon,
          title: title,
          trailing: trailing,
          open: open,
          onTap: () {
            setState(() => _openGroup = open ? null : id);
            onHeaderTap?.call();
          },
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: open
              ? Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: children,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  /// Borderless settings tile — the desktop shell's surface grammar: a
  /// `glassFill` tone step carries the edge, no hairline, radius 12 like the
  /// rail's icon box. **Tiles hold ROWS** (toggles, key/value groups). Chips
  /// and buttons sit on the stage beside them, never inside one: a filled
  /// control in a filled tile is the box-in-a-box this replaced. A tile with
  /// [onTap] brightens on hover.
  Widget _tile(GlassTokens tokens, {required Widget child, VoidCallback? onTap}) {
    return Material(
      color: tokens.glassFill,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: tokens.glassFill,
        highlightColor: tokens.glassFill,
        splashColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: child,
        ),
      ),
    );
  }

  /// A toggle row: the whole tile flips the switch. No leading icon — the
  /// section header already names the group.
  Widget _toggleRow(
    GlassTokens tokens, {
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return _tile(
      tokens,
      onTap: () => onChanged(!value),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    color: tokens.starkWhite,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    color: tokens.textDim,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Teal only while ON (it is the state); off is grey on grey with
          // no outline ring, which M3 draws by default.
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            activeThumbColor: tokens.connectedAccent,
            activeTrackColor: tokens.connectedAccent.withValues(alpha: 0.25),
            inactiveThumbColor: tokens.textDim,
            inactiveTrackColor: tokens.surfaceElevated,
            trackOutlineColor:
                const WidgetStatePropertyAll(Colors.transparent),
          ),
        ],
      ),
    );
  }

  Widget _pillBadge(GlassTokens tokens, String label, Color color) {
    // No ring: the tint already says it (the borderless rule).
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'SpaceGrotesk',
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.5,
          color: color,
        ),
      ),
    );
  }

  Widget _kvRow(
    GlassTokens tokens,
    String label,
    String value, {
    String? copyable,
    void Function(String)? onCopy,
  }) {
    // Field label speaks the caps eyebrow voice of [_miniLabel], so every
    // in-page field label (POLLING RATE, CHAIN ID, …) reads the same.
    return Row(
      children: [
        SizedBox(
          width: 90,
          child: _miniLabel(tokens, label.toUpperCase()),
        ),
        Expanded(
          child: copyable != null
              ? GestureDetector(
                  onTap: () => onCopy?.call(copyable),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          value,
                          style: TextStyle(
                    fontFamily: 'monospace',
                            fontSize: 12,
                            color: tokens.starkWhite,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.copy_rounded,
                        size: 11,
                        color: tokens.textDim,
                      ),
                    ],
                  ),
                )
              : Text(
                  value,
                  style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: tokens.starkWhite,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
        ),
      ],
    );
  }

  Widget _devChip(
    GlassTokens tokens,
    IconData icon,
    String label, {
    required bool loading,
    required VoidCallback? onTap,
  }) {
    return Material(
      color: tokens.glassFill,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: tokens.glassFill,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const PhigitalLoadingWidget(size: 14, showShadows: false)
              else
                Icon(icon,
                    size: 14,
                    color: onTap == null ? tokens.textDim : tokens.starkWhite),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'SpaceGrotesk',
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: onTap == null ? tokens.textDim : tokens.starkWhite,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _destructiveButton(
    GlassTokens tokens, {
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    // Borderless: the orange tint carries "destructive" by itself.
    return SizedBox(
      width: double.infinity,
      child: TextButton.icon(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor: tokens.fallbackAccent.withValues(alpha: 0.10),
          foregroundColor: tokens.fallbackAccent,
          disabledBackgroundColor: tokens.glassFill,
          disabledForegroundColor: tokens.textDim,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        icon: Icon(icon, size: 16),
        label: Text(
          label,
          style: const TextStyle(
            fontFamily: 'SpaceGrotesk',
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
          ),
        ),
      ),
    );
  }

  String _truncateUrl(String url) {
    if (url.length <= 40) return url;
    return '${url.substring(0, 20)}...${url.substring(url.length - 16)}';
  }
}

// ── Group header ──────────────────────────────────────────────────────────────

/// The tappable header of a [_AppSettingsPageState._group]. Grey glyphs that turn
/// white on hover or while open (the rail's selected/hovered grammar); the
/// title stays white. Teal is never used here: open is a place, not a state.
class _GroupHeader extends StatefulWidget {
  final IconData icon;
  final String title;
  final Widget? trailing;
  final bool open;
  final VoidCallback onTap;

  const _GroupHeader({
    required this.icon,
    required this.title,
    required this.trailing,
    required this.open,
    required this.onTap,
  });

  @override
  State<_GroupHeader> createState() => _GroupHeaderState();
}

class _GroupHeaderState extends State<_GroupHeader> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final fg = (_hovered || widget.open) ? tokens.starkWhite : tokens.textDim;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        // Open = a really light `glassFill` wash, so it stands out; a
        // hovered closed header gets half of that, so hover
        // never reads as open. The 14 px inset matches the tiles below, so the
        // wash's edge lines up with theirs and the glyph lines up with their
        // text.
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: widget.open
                ? tokens.glassFill
                : _hovered
                    ? tokens.glassFill.withValues(alpha: tokens.glassFill.a / 2)
                    : tokens.glassFill.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(widget.icon, color: fg, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.title,
                  style: TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    color: tokens.starkWhite,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              if (widget.trailing != null) ...[
                widget.trailing!,
                const SizedBox(width: 10),
              ],
              AnimatedRotation(
                turns: widget.open ? 0.25 : 0,
                duration: const Duration(milliseconds: 180),
                child: Icon(Icons.chevron_right_rounded, size: 18, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Polling chip (split out because it's const-ish)
// ═══════════════════════════════════════════════════════════════════════════

Widget _pollingChip(
  GlassTokens tokens,
  int minutes,
  bool active,
  ValueChanged<int> onChanged,
) {
  String label;
  if (minutes < 60) {
    label = '${minutes}m';
  } else if (minutes < 1440) {
    label = '${minutes ~/ 60}h';
  } else {
    label = '${minutes ~/ 1440}d';
  }
  return _choiceChip(tokens, label, active, () => onChanged(minutes));
}

/// Pick-one chip for the settings pickers (language, polling rate). Borderless
/// with the shell chip's exact values (`ExplorerChip`: glassFill inactive,
/// surfaceElevated active, radius 18, 12/8 padding, w500/w700), so the pickers
/// match the Contacts / Messages chip bars.
Widget _choiceChip(
  GlassTokens tokens,
  String label,
  bool active,
  VoidCallback onTap,
) {
  return Material(
    color: active ? tokens.surfaceElevated : tokens.glassFill,
    borderRadius: BorderRadius.circular(18),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      hoverColor: tokens.glassFill,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            fontSize: 12,
            height: 1.3,
            letterSpacing: 0.3,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? tokens.starkWhite : tokens.textDim,
          ),
        ),
      ),
    ),
  );
}


// ═══════════════════════════════════════════════════════════════════════════
// Register DAO dialog
// ═══════════════════════════════════════════════════════════════════════════

class _RegisterDAODialog extends StatefulWidget {
  final EthereumAddress? existingAddress;
  final Contact? existingContact;

  const _RegisterDAODialog({
    this.existingAddress,
    this.existingContact,
  });

  @override
  State<_RegisterDAODialog> createState() => _RegisterDAODialogState();
}

class _RegisterDAODialogState extends State<_RegisterDAODialog> {
  final _addressCtrl = TextEditingController();
  bool _showInput = false;

  @override
  void initState() {
    super.initState();
    _showInput = widget.existingAddress == null;
  }

  @override
  void dispose() {
    _addressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    return AlertDialog(
      constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.m),
      backgroundColor: tokens.surfaceDeep,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: tokens.borderSubtle),
      ),
      title: Text(
        l10n.appSettingsPageRegisterDaoTitle,
        style: TextStyle(
              fontFamily: 'SpaceGrotesk',
          color: tokens.starkWhite,
          fontWeight: FontWeight.w800,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.existingAddress != null && !_showInput) ...[
              Text(
                l10n.appSettingsPageDaoAlreadyRegistered,
                style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                  color: tokens.textDim,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: tokens.glassFill,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: tokens.borderSubtle),
                ),
                child: Row(
                  children: [
                    if (widget.existingContact != null)
                      GlassContactIcon(
                        contact: widget.existingContact,
                        address: widget.existingAddress!.eip55With0x,
                        size: 36,
                      )
                    else
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: tokens.glassFill,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: tokens.borderSubtle),
                        ),
                        child: Icon(
                          Icons.account_balance_rounded,
                          color: tokens.connectedAccent,
                          size: 18,
                        ),
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.existingContact != null)
                            Text(
                              widget.existingContact!.displayName,
                              style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                                color: tokens.starkWhite,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          Text(
                            widget.existingAddress!.eip55With0x,
                            style: TextStyle(
                    fontFamily: 'monospace',
                              color: tokens.textDim,
                              fontSize: 10,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              TextButton.icon(
                onPressed: () => setState(() => _showInput = true),
                icon: Icon(
                  Icons.edit_outlined,
                  color: tokens.connectedAccent,
                  size: 16,
                ),
                label: Text(
                  l10n.appSettingsPageUpdateDaoAddress,
                  style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                    color: tokens.connectedAccent,
                    fontSize: 13,
                  ),
                ),
              ),
            ] else ...[
              Text(
                l10n.appSettingsPageEnterDaoAddress,
                style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                  color: tokens.textDim,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),
              _GlassField(
                tokens: tokens,
                controller: _addressCtrl,
                label: l10n.appSettingsPageDaoAddressLabel,
                hint: '0x...',
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            l10n.dlgCancel,
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',color: tokens.textDim),
          ),
        ),
        if (_showInput)
          TextButton(
            onPressed: () {
              final address = _addressCtrl.text.trim();
              if (address.isEmpty ||
                  !address.startsWith('0x') ||
                  address.length != 42) {
                return;
              }
              Navigator.pop(context, address);
            },
            child: Text(
              l10n.appSettingsPageRegisterButton,
              style: TextStyle(
              fontFamily: 'SpaceGrotesk',
                color: tokens.connectedAccent,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Glass text field (copied from account_center — kept private per-file
// so each system-app page is self-contained)
// ═══════════════════════════════════════════════════════════════════════════

class _GlassField extends StatelessWidget {
  final GlassTokens tokens;
  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? errorText;
  final bool enabled;

  const _GlassField({
    required this.tokens,
    required this.controller,
    required this.label,
    this.hint,
    this.errorText,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      style: TextStyle(
              fontFamily: 'SpaceGrotesk',
        color: enabled ? tokens.starkWhite : tokens.textDim,
        fontSize: 14,
      ),
      cursorColor: tokens.starkWhite,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: errorText,
        labelStyle: TextStyle(
              fontFamily: 'SpaceGrotesk',
          color: tokens.textDim,
          fontSize: 13,
        ),
        hintStyle: TextStyle(
              fontFamily: 'SpaceGrotesk',
          color: tokens.textDim.withValues(alpha: 0.6),
          fontSize: 13,
        ),
        filled: true,
        fillColor: tokens.glassFill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: tokens.borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: tokens.borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: tokens.connectedAccent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: tokens.fallbackAccent),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
      ),
    );
  }
}

/// Profiles the viewer said "I'm 18+" to (Core settings `mature_ok.<address>`,
/// written by the browser's mature gate). Icon + name on the left,
/// a tap opens the profile, the red bin deletes the setting so the profile asks
/// again next time.
class _MatureProfilesList extends StatefulWidget {
  const _MatureProfilesList();

  @override
  State<_MatureProfilesList> createState() => _MatureProfilesListState();
}

class _MatureProfilesListState extends State<_MatureProfilesList> {
  static const _prefix = 'mature_ok.';
  List<({String key, String address, Contact? contact})>? _rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = <({String key, String address, Contact? contact})>[];
    try {
      final all = await PublicOSSettings.getAllSettings();
      for (final e in all.entries) {
        if (!e.key.startsWith(_prefix) || e.value.value != 'true') continue;
        final address = e.key.substring(_prefix.length);
        Contact? contact;
        try {
          contact = await PublicOSContacts.getContact(EthereumAddress.fromHex(address));
        } catch (_) {}
        rows.add((key: e.key, address: address, contact: contact));
      }
    } catch (_) {} // signed out: nothing kept
    if (mounted) setState(() => _rows = rows);
  }

  Future<void> _remove(String key) async {
    try {
      await PublicOSSettings.deleteSetting(key);
    } catch (_) {}
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    final rows = _rows;
    if (rows == null) return const SizedBox(height: 48);
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Text(
          l10n.settingsMatureProfilesEmpty,
          style: TextStyle(
              fontFamily: 'SpaceGrotesk', color: tokens.textDim, fontSize: 12, height: 1.4),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in rows) ...[
          Material(
            color: tokens.glassFill,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => AppNav.toProfile(context, r.address),
              hoverColor: tokens.glassFill,
              highlightColor: tokens.glassFill,
              splashColor: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Row(
                  children: [
                    GlassContactIcon(contact: r.contact, address: r.address, size: 36),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        r.contact?.publicosDisplayName ??
                            r.contact?.displayName ??
                            '${r.address.substring(0, 6)}…${r.address.substring(r.address.length - 4)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'SpaceGrotesk',
                          color: tokens.starkWhite,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.settingsMatureProfilesRemove,
                      icon: Icon(Icons.delete_outline_rounded,
                          size: 20, color: tokens.softDanger),
                      onPressed: () => _remove(r.key),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}
