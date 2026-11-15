import 'package:publicos_core/publicos_core.dart';
import 'package:zero_cached_image/zero_cached_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:publicos_client/router_helpers.dart';
import 'package:publicos_client/components/glass_contact_icon.dart';
import 'package:publicos_client/providers/theme_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:publicos_client/utils/own_links.dart';
import 'package:publicos_client/router.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';

/// Store icon URLs
const String _appStoreIconUrl =
    'https://www.apple.com/v/app-store/c/images/overview/icon_appstore__ev0z770zyxoy_medium.png';
const String _playStoreIconUrl =
    'https://upload.wikimedia.org/wikipedia/commons/thumb/7/78/Google_Play_Store_badge_EN.svg/270px-Google_Play_Store_badge_EN.svg.png';

class AppProfileBottomSheet extends StatelessWidget {
  final AppBookmark app;
  final Contact? ownerContact;
  final VoidCallback? onOpenInBrowser;
  final VoidCallback? onEdit;
  final VoidCallback? onRemoveBookmark;
  final VoidCallback? onAddBookmark;

  const AppProfileBottomSheet({
    super.key,
    required this.app,
    this.ownerContact,
    this.onOpenInBrowser,
    this.onEdit,
    this.onRemoveBookmark,
    this.onAddBookmark,
  });

  bool get _isOwnedByCurrentUser {
    final currentAddress = AppStateNotifier.currentMyContact?.publicosAddress;
    if (currentAddress == null) return false;
    return currentAddress.eip55With0x.toLowerCase() ==
        app.ownerAccountAddress.eip55With0x.toLowerCase();
  }

  Widget _buildBookmarkButton(BuildContext context, bool isDark) {
    final isBookmarked = onRemoveBookmark != null;
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        Navigator.pop(context);
        if (isBookmarked) {
          onRemoveBookmark!();
        } else {
          onAddBookmark?.call();
        }
      },
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : ThemeProvider.slateDarkest.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(PhigitalStyle.radiusButton),
          boxShadow: PhigitalStyle.smallShadow(isDark),
        ),
        child: Icon(
          isBookmarked ? Icons.bookmark_rounded : Icons.bookmark_add_outlined,
          size: 18,
          color: isBookmarked
              ? ThemeProvider.tealPrimary
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final subtleBg = PhigitalStyle.subtleTint(isDark);

    const double bannerHeight = 120;
    const double avatarSize = 72;
    const double avatarOverlap = 36; // half the avatar hangs below the banner

    final bannerUrl = ownerContact?.bannerUrl ?? Contact.defaultBannerUrl;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Banner + overlapping avatar
          SizedBox(
            height: bannerHeight + avatarOverlap,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Banner image
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  child: SizedBox(
                    height: bannerHeight,
                    width: double.infinity,
                    child: ZeroCachedImage(
                      imageUrl: bannerUrl,
                      fit: BoxFit.cover,
                      fadeInDuration: Duration.zero,
                      fadeOutDuration: Duration.zero,
                      errorWidget: (context, url, error) => Container(
                        color: ThemeProvider.tealPrimary.withValues(alpha: 0.15),
                      ),
                    ),
                  ),
                ),
                // Dark scrim for readability of top-right buttons
                Positioned(
                  top: 0, right: 0, left: 0,
                  height: 48,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.35),
                          Colors.black.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
                // Handle bar floating on banner
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(top: 10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                // Edit button (owner only) — top-right on banner
                if (_isOwnedByCurrentUser && onEdit != null)
                  Positioned(
                    top: 10,
                    right: 12,
                    child: GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        onEdit!();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.edit_rounded, size: 14, color: ThemeProvider.amberAccent),
                            const SizedBox(width: 4),
                            Text(
                              context.l10n.appProfileBottomSheetEdit,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                // App icon overlapping the banner bottom
                Positioned(
                  left: 20,
                  bottom: 0,
                  child: Container(
                    width: avatarSize,
                    height: avatarSize,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      color: theme.scaffoldBackgroundColor,
                      border: Border.all(color: theme.scaffoldBackgroundColor, width: 3),
                      boxShadow: PhigitalStyle.cardShadow(isDark),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(15),
                      child: app.icon != null && app.icon!.isNotEmpty
                          ? ZeroCachedImage(
                              imageUrl: app.icon!,
                              fit: BoxFit.cover,
                              fadeInDuration: Duration.zero,
                              fadeOutDuration: Duration.zero,
                              errorWidget: (context, url, error) => Icon(
                                Icons.apps_rounded,
                                size: 36,
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                              ),
                            )
                          : Container(
                              color: subtleBg,
                              child: Icon(
                                Icons.apps_rounded,
                                size: 36,
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Name, creator, badges — below the banner+avatar area
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        app.displayName,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                    if (!_isOwnedByCurrentUser) ...[
                      const SizedBox(width: 12),
                      _buildBookmarkButton(context, isDark),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                // "by [creator]" row
                GestureDetector(
                  onTap: () => _navigateToOwner(context),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (ownerContact != null) ...[
                        GlassContactIcon(
                          contact: ownerContact!,
                          size: 20,
                        ),
                        const SizedBox(width: 6),
                      ] else ...[
                        Icon(Icons.person_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        context.l10n.appProfileBottomSheetByPrefix,
                        style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
                      ),
                      Flexible(
                        child: Text(
                          ownerContact?.displayName ??
                              _formatAddress(app.ownerAccountAddress.eip55With0x),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: ThemeProvider.tealPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.arrow_forward_ios_rounded, size: 10, color: ThemeProvider.tealPrimary),
                    ],
                  ),
                ),
                // Platform availability badges
                if (_hasAnyPlatform) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: _buildPlatformBadges(context, theme, isDark),
                  ),
                ],
              ],
            ),
          ),

          // Rest of content with horizontal padding
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Categories
                if (_hasCategories) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _buildCategoryChips(theme, isDark),
                  ),
                ],

                // Description
                if (app.description != null && app.description!.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(
                    context.l10n.appProfileBottomSheetAbout,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    app.description!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.5,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],

                // Warnings
                if (_hasWarnings) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.orange.shade900.withValues(alpha: 0.2)
                          : Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark
                            ? Colors.orange.shade700.withValues(alpha: 0.4)
                            : Colors.orange.shade200,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.orange.withValues(alpha: isDark ? 0.15 : 0.08),
                          blurRadius: 0,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.orange.shade700,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            app.getPointer('warnings')!.value,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: isDark
                                  ? Colors.orange.shade200
                                  : Colors.orange.shade900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                // Launch Buttons Section
                const SizedBox(height: 24),
                Text(
                  context.l10n.appProfileBottomSheetOpenApp,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),

                // Web App Button (primary)
                if (app.url != null && app.url!.isNotEmpty) ...[
                  _buildPhigitalButton(
                    context: context,
                    icon: Icons.public_rounded,
                    label: context.l10n.appProfileBottomSheetOpenWebApp,
                    color: ThemeProvider.tealPrimary,
                    isPrimary: true,
                    onTap: () {
                      Navigator.pop(context);
                      onOpenInBrowser?.call();
                    },
                  ),
                  const SizedBox(height: 12),
                ],

                // Store Buttons with actual icons
                if (_hasAppStoreLink || _hasPlayStoreLink) ...[
                  Row(
                    children: [
                      if (_hasAppStoreLink)
                        Expanded(
                          child: _buildStoreButton(
                            context: context,
                            iconUrl: _appStoreIconUrl,
                            fallbackIcon: Icons.apple,
                            label: 'App Store',
                            onTap: () =>
                                _launchUrl(app.getPointer('appstore_link')!.value),
                          ),
                        ),
                      if (_hasAppStoreLink && _hasPlayStoreLink)
                        const SizedBox(width: 12),
                      if (_hasPlayStoreLink)
                        Expanded(
                          child: _buildStoreButton(
                            context: context,
                            iconUrl: _playStoreIconUrl,
                            fallbackIcon: Icons.android,
                            label: 'Play Store',
                            onTap: () =>
                                _launchUrl(app.getPointer('playstore_link')!.value),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],

                // Direct Download Buttons
                if (_hasApkDownload || _hasIpaDownload) ...[
                  Row(
                    children: [
                      if (_hasApkDownload)
                        Expanded(
                          child: _buildPhigitalButton(
                            context: context,
                            icon: Icons.android_rounded,
                            label: context.l10n.appProfileBottomSheetDownloadApk,
                            color: Colors.green.shade600,
                            onTap: () =>
                                _launchUrl(app.getPointer('apk_download')!.value),
                          ),
                        ),
                      if (_hasApkDownload && _hasIpaDownload)
                        const SizedBox(width: 12),
                      if (_hasIpaDownload)
                        Expanded(
                          child: _buildPhigitalButton(
                            context: context,
                            icon: Icons.apple_rounded,
                            label: context.l10n.appProfileBottomSheetDownloadIpa,
                            color: Colors.grey.shade600,
                            onTap: () =>
                                _launchUrl(app.getPointer('ipa_download')!.value),
                          ),
                        ),
                    ],
                  ),
                ],

                // Remove Bookmark — subtle text-only link
                // if (!_isOwnedByCurrentUser && onRemoveBookmark != null) ...[
                //   const SizedBox(height: 24),
                //   Center(
                //     child: GestureDetector(
                //       onTap: () {
                //         HapticFeedback.lightImpact();
                //         Navigator.pop(context);
                //         onRemoveBookmark!();
                //       },
                //       child: Padding(
                //         padding: const EdgeInsets.symmetric(vertical: 4),
                //         child: Text(
                //           'Remove bookmark',
                //           style: TextStyle(
                //             fontSize: 13,
                //             color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                //           ),
                //         ),
                //       ),
                //     ),
                //   ),
                // ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool get _hasCategories =>
      (app.getPointer('category_one') != null &&
          app.getPointer('category_one')!.value.isNotEmpty) ||
      (app.getPointer('category_two') != null &&
          app.getPointer('category_two')!.value.isNotEmpty);

  bool get _hasWarnings =>
      app.getPointer('warnings') != null &&
      app.getPointer('warnings')!.value.isNotEmpty;

  bool get _hasAppStoreLink =>
      app.getPointer('appstore_link') != null &&
      app.getPointer('appstore_link')!.value.isNotEmpty;

  bool get _hasPlayStoreLink =>
      app.getPointer('playstore_link') != null &&
      app.getPointer('playstore_link')!.value.isNotEmpty;

  bool get _hasApkDownload =>
      app.getPointer('apk_download') != null &&
      app.getPointer('apk_download')!.value.isNotEmpty;

  bool get _hasIpaDownload =>
      app.getPointer('ipa_download') != null &&
      app.getPointer('ipa_download')!.value.isNotEmpty;

  bool get _hasWebApp => app.url != null && app.url!.isNotEmpty;

  bool get _hasIOS => _hasAppStoreLink || _hasIpaDownload;

  bool get _hasAndroid => _hasPlayStoreLink || _hasApkDownload;

  bool get _hasAnyPlatform => _hasWebApp || _hasIOS || _hasAndroid;

  List<Widget> _buildPlatformBadges(
      BuildContext context, ThemeData theme, bool isDark) {
    final badges = <Widget>[];

    if (_hasWebApp) {
      badges.add(_buildPlatformBadge(
        icon: Icons.language_rounded,
        label: context.l10n.appProfileBottomSheetPlatformWeb,
        color: ThemeProvider.tealPrimary,
        isDark: isDark,
      ));
    }

    if (_hasIOS) {
      badges.add(_buildPlatformBadge(
        icon: Icons.apple_rounded,
        label: 'iOS',
        color: Colors.grey.shade600,
        isDark: isDark,
      ));
    }

    if (_hasAndroid) {
      badges.add(_buildPlatformBadgeWithImage(
        imageUrl: 'https://www.gstatic.com/android/market_images/web/favicon_v3.ico',
        fallbackIcon: Icons.android_rounded,
        label: 'Android',
        color: Colors.green.shade600,
        isDark: isDark,
      ));
    }

    return badges;
  }

  Widget _buildPlatformBadge({
    required IconData icon,
    required String label,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.15 : 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlatformBadgeWithImage({
    required String imageUrl,
    required IconData fallbackIcon,
    required String label,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.15 : 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: ZeroCachedImage(
              imageUrl: imageUrl,
              width: 12,
              height: 12,
              fit: BoxFit.contain,
              errorWidget: (context, url, error) => Icon(
                fallbackIcon,
                size: 12,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildCategoryChips(ThemeData theme, bool isDark) {
    final chips = <Widget>[];
    final chipBg = PhigitalStyle.subtleTint(isDark);
    final chipBorder = PhigitalStyle.subtleBorder(isDark);

    final cat1 = app.getPointer('category_one');
    if (cat1 != null && cat1.value.isNotEmpty) {
      chips.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: chipBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: chipBorder),
          ),
          child: Text(
            cat1.value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    final cat2 = app.getPointer('category_two');
    if (cat2 != null && cat2.value.isNotEmpty) {
      chips.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: chipBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: chipBorder),
          ),
          child: Text(
            cat2.value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return chips;
  }

  Widget _buildPhigitalButton({
    required BuildContext context,
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    bool isPrimary = false,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (isPrimary) {
      return GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.4),
                blurRadius: 0,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 22),
              const SizedBox(width: 10),
              Text(
                label,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Secondary button
    final btnBg = PhigitalStyle.subtleTint(isDark);
    final btnBorder = PhigitalStyle.subtleBorder(isDark);

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: btnBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: btnBorder),
          boxShadow: PhigitalStyle.smallShadow(isDark),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStoreButton({
    required BuildContext context,
    required String iconUrl,
    required IconData fallbackIcon,
    required String label,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final btnBg = PhigitalStyle.subtleTint(isDark);
    final btnBorder = PhigitalStyle.subtleBorder(isDark);

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        decoration: BoxDecoration(
          color: btnBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: btnBorder),
          boxShadow: PhigitalStyle.smallShadow(isDark),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: ZeroCachedImage(
                imageUrl: iconUrl,
                width: 24,
                height: 24,
                fit: BoxFit.contain,
                errorWidget: (context, url, error) => Icon(
                  fallbackIcon,
                  size: 24,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatAddress(String address) {
    if (address.length <= 10) return address;
    return '${address.substring(0, 6)}...${address.substring(address.length - 4)}';
  }

  void _navigateToOwner(BuildContext context) {
    Navigator.pop(context);
    AppNav.toProfile(context, app.ownerAccountAddress.eip55With0x);
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (routeOwnLink(uri)) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
