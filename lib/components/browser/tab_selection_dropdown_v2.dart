import 'package:publicos_core/publicos_core.dart';
import 'package:zero_cached_image/zero_cached_image.dart';
import 'package:flutter/material.dart';
import 'package:publicos_client/providers/theme_provider.dart';
import '../../app_routes.dart';
import '../profile/tab_icon_widget.dart';
import 'tab_selection_dropdown.dart'; // Import for TabItem and TabSection classes

class TabSelectionDropdownV2 {
  static void show({
    required BuildContext context,
    required GlobalKey containerKey,
    required List<TabSection> sections,
    required Function(TabItem?) onTabSelected,
  }) {
    final renderBox = containerKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final offset = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    print('Trigger position: $offset, size: $size');
    // Simple showDialog approach for safety
    showDialog(
      context: context,
      barrierColor: Colors.transparent,
      builder: (BuildContext context) {
        return Stack(
          children: [
            // Invisible barrier to close on tap outside
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: double.infinity,
                height: double.infinity,
                color: Colors.transparent,
              ),
            ),
            // Positioned dropdown anchored to RIGHT side of trigger
            Positioned(
              right: MediaQuery.of(context).size.width - (offset.dx + size.width) , // Anchor to right side of trigger + 16px left offset
              top: offset.dy , // 8px below the trigger
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: offset.dx + size.width , // Can extend leftward to screen edge
                  maxHeight: MediaQuery.of(context).size.height - (offset.dy + size.height + 8) - 20, // Prevent bottom overflow
                ),
                child: Material(
                  color: Colors.transparent,
                  child: _buildAlignedDropdown(context, size, sections, onTabSelected),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static Widget _buildAlignedDropdown(
    BuildContext context,
    Size triggerSize,
    List<TabSection> sections,
    Function(TabItem?) onTabSelected,
  ) {
    // Flatten sections into items
    final allItems = <TabItem>[];
    for (final section in sections) {
      allItems.addAll(section.items);
    }

    // Calculate the maximum text width needed
    final maxTextWidth = _calculateMaxTextWidth(context, allItems);

    return Container(
      padding: const EdgeInsets.all(4.0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end, // Align to the right
          children: allItems.map((item) {
            return Container(
              margin: const EdgeInsets.only(bottom: 8.0), // Consistent vertical spacing
              child: _buildTabContainer(context, item, triggerSize, onTabSelected, maxTextWidth),
            );
          }).toList(),
        ),
      ),
    );
  }

  static double _calculateMaxTextWidth(BuildContext context, List<TabItem> items) {
    double maxWidth = 0;

    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
      fontSize: 14,
    );

    for (final item in items) {
      final textPainter = TextPainter(
        text: TextSpan(text: item.label, style: textStyle),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();

      if (textPainter.width > maxWidth) {
        maxWidth = textPainter.width;
      }
    }

    return maxWidth;
  }

  static Widget _buildTabContainer(
    BuildContext context,
    TabItem item,
    Size triggerSize,
    Function(TabItem?) onTabSelected,
    double maxTextWidth,
  ) {
    final color = _getTabColor(context, item);

    return GestureDetector(
      onTap: () {
        Navigator.of(context).pop(); // Close dialog
        onTabSelected(item);
      },
      child: Container(
        width: maxTextWidth + 32 + 20 + 8 + 28 + 40, // Text width + horizontal padding + icon width + spacing
        height: triggerSize.height.clamp(48.0, double.infinity), // Ensure minimum height
        constraints: const BoxConstraints(minWidth: 120), // Minimum width for text visibility
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          border: Border.all(
            color: Theme.of(context).dividerColor,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(PhigitalStyle.radiusCard),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              item.label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: _getTextColor(color),
                fontSize: 14,
              ),
              textAlign: TextAlign.right,
            ),
            const SizedBox(width: 8),
            _buildTabIcon(context, item, color),
          ],
        ),
      ),
    );
  }

  static Widget _buildTabIcon(BuildContext context, TabItem item, Color backgroundColor) {
    final iconColor = _getTextColor(backgroundColor);

    if (item.isCustomTab && item.record != null) {
      return SizedBox(
        width: 20,
        height: 20,
        child: TabIconWidget(
          record: item.record!,
          size: 20,
        ),
      );
    } else if (item.isBrowserTab && item.browserTab != null) {
      return Icon(_getTabIcon(item.browserTab!), size: 20, color: iconColor);
    } else if (item.isChatTab) {
      return Icon(Icons.chat_bubble_outline, size: 20, color: iconColor);
    } else if (item.isAppTab && item.appBookmark != null) {
      // App tab - show app icon or default app icon
      if (item.appBookmark!.icon != null && item.appBookmark!.icon!.isNotEmpty) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child:

            ZeroCachedImage(
              width: 20,
              height: 20,
              imageUrl: item.appBookmark!.icon!,
              fit: BoxFit.cover,
              fadeInDuration: Duration.zero,
              fadeOutDuration: Duration.zero,
              errorWidget: (context, url, error) => Icon(
                    Icons.apps_rounded,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                  ))
        );
      }
      return Icon(Icons.apps_rounded, size: 20, color: iconColor);
    } else {
      return Icon(Icons.tab, size: 20, color: iconColor);
    }
  }

  static Color _getTabColor(BuildContext context, TabItem item) {
    final theme = Theme.of(context);

    if (item.isBrowserTab && item.browserTab != null) {
      switch (item.browserTab!) {
        case BrowserTab.profile:
          return theme.primaryColor;
        case BrowserTab.chat:
          return ThemeProvider.successLight;
        case BrowserTab.settings:
          return ThemeProvider.slateLight;
        case BrowserTab.management:
          return theme.primaryColor;
        case BrowserTab.webview:
          return ThemeProvider.infoLight;
        case BrowserTab.channel:
          return ThemeProvider.amberAccent;
        case BrowserTab.app:
          return ThemeProvider.errorLight;
      }
    } else if (item.isChatTab) {
      return ThemeProvider.successLight;
    } else if (item.isCustomTab && item.record != null) {
      final record = item.record!;
      final isRssTab = record.routerSubtype == RouterSubtype.channel;
      return isRssTab
          ? ThemeProvider.amberAccent
          : ThemeProvider.infoLight;
    } else if (item.isAppTab && item.appBookmark != null) {
      // App tabs - error/red color matching browser.dart
      return ThemeProvider.errorLight;
    }

    return theme.cardColor;
  }

  static Color _getTextColor(Color backgroundColor) {
    final luminance = backgroundColor.computeLuminance();
    return luminance > 0.5 ? Colors.black87 : Colors.white;
  }

  static IconData _getTabIcon(BrowserTab tab) {
    switch (tab) {
      case BrowserTab.profile:
        return Icons.person_outline;
      case BrowserTab.chat:
        return Icons.chat_bubble_outline;
      case BrowserTab.management:
        return Icons.admin_panel_settings_outlined;
      case BrowserTab.settings:
        return Icons.settings_outlined;
      case BrowserTab.webview:
        return Icons.public_outlined;
      case BrowserTab.channel:
        return Icons.rss_feed;
      case BrowserTab.app:
        return Icons.apps_rounded;
    }
  }
}
