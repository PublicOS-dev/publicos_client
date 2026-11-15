import 'package:publicos_core/publicos_core.dart';
import 'package:flutter/material.dart';
import 'package:zero_cached_image/zero_cached_image.dart';
import '../../app_routes.dart';
import '../profile/tab_icon_widget.dart';

class TabItem {
  final BrowserTab? browserTab;
  final String? inboxId;
  final Record? record;
  final AppBookmark? appBookmark;
  final String label;
  final IconData? icon;

  /// True when this chat entry points at the inbox THIS DEVICE currently has
  /// loaded (`PublicOS.clientXmtpInboxId`). It is shown, dimmed and inert -
  /// you cannot message yourself, and hiding it makes the entry look lost.
  /// Not a "my own profile" test: the same match
  /// happens on an org whose Admin key you hold.
  final bool isLoadedInbox;

  const TabItem({
    this.browserTab,
    this.inboxId,
    this.record,
    this.appBookmark,
    required this.label,
    this.icon,
    this.isLoadedInbox = false,
  });

  bool get isBrowserTab => browserTab != null && appBookmark == null && inboxId == null && record == null;
  bool get isChatTab => inboxId != null;
  bool get isCustomTab => record != null;
  bool get isAppTab => appBookmark != null;
}

class TabSection {
  final List<TabItem> items;
  final bool needsDivider;
  final bool isScrollable;
  
  const TabSection({
    required this.items,
    this.needsDivider = false,
    this.isScrollable = false,
  });
}

class TabSelectionDropdown {
  static Future<TabItem?> show({
    required BuildContext context,
    required GlobalKey containerKey,
    required List<TabSection> sections,
  }) async {
    final RenderBox? renderBox = containerKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return null;

    final Offset offset = renderBox.localToGlobal(Offset.zero);
    final Size size = renderBox.size;

    List<PopupMenuEntry<TabItem>> menuItems = [];

    for (int sectionIndex = 0; sectionIndex < sections.length; sectionIndex++) {
      final section = sections[sectionIndex];
      
      if (sectionIndex > 0 && section.needsDivider) {
        menuItems.add(const PopupMenuDivider());
      }

      if (section.isScrollable && section.items.length > 5) {
        // Create scrollable section for more than 5 items
        menuItems.add(
          PopupMenuItem<TabItem>(
            enabled: false,
            child: Container(
              height: 200, // Fixed height for scrollable area
              width: double.infinity,
              child: ListView.builder(
                itemCount: section.items.length,
                itemBuilder: (context, index) {
                  final item = section.items[index];
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: Text(
                      item.label,
                      textAlign: TextAlign.right,
                    ),
                    trailing: _buildItemIcon(item),
                    onTap: () {
                      Navigator.pop(context, item);
                    },
                  );
                },
              ),
            ),
          ),
        );
      } else {
        // Regular menu items
        menuItems.addAll(
          section.items.map((item) {
            return PopupMenuItem<TabItem>(
              value: item,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Expanded(
                    child: Text(
                      item.label,
                      textAlign: TextAlign.right,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildItemIcon(item),
                ],
              ),
            );
          }).toList(),
        );
      }
    }

    return showMenu<TabItem>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(offset.dx, offset.dy + size.height, size.width, 0),
        Offset.zero & MediaQuery.of(context).size,
      ),
      items: menuItems,
      elevation: 8,
    );
  }

  static Widget _buildItemIcon(TabItem item) {
    if (item.isAppTab && item.appBookmark != null) {
      // App tab - show app icon or default app icon
      if (item.appBookmark!.icon != null && item.appBookmark!.icon!.isNotEmpty) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: ZeroCachedImage(
            imageUrl: item.appBookmark!.icon!,
            width: 20,
            height: 20,
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) => const Icon(Icons.apps_rounded, size: 20),
          ),
        );
      }
      return const Icon(Icons.apps_rounded, size: 20);
    } else if (item.isCustomTab && item.record != null) {
      return SizedBox(
        width: 20,
        height: 20,
        child: TabIconWidget(
          record: item.record!,
          size: 20,
        ),
      );
    } else if (item.isBrowserTab && item.browserTab != null) {
      return Icon(_getTabIcon(item.browserTab!), size: 20);
    } else if (item.isChatTab) {
      return const Icon(Icons.chat_bubble_outline, size: 20);
    } else if (item.icon != null) {
      return Icon(item.icon, size: 20);
    } else {
      return const SizedBox(width: 20, height: 20);
    }
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