import 'package:publicos_core/publicos_core.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/providers/theme_provider.dart';

class FloatingContactMenu extends StatefulWidget {
  final Contact contact;
  final VoidCallback? onDelete;
  final Offset position;
  final VoidCallback? onDismiss;

  const FloatingContactMenu({
    super.key,
    required this.contact,
    required this.position,
    this.onDelete,
    this.onDismiss,
  });

  @override
  State<FloatingContactMenu> createState() => _FloatingContactMenuState();
}

class _FloatingContactMenuState extends State<FloatingContactMenu>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _scaleAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutBack,
    ));

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    ));

    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _shareContact(BuildContext context) {
    final l10n = context.l10n;
    final contactInfo = StringBuffer();
    contactInfo.writeln(
        l10n.floatingContactMenuShareContactLabel(widget.contact.displayName));

    if (widget.contact.publicosAddress != null) {
      contactInfo.writeln(l10n.floatingContactMenuShareAddressLabel(
          widget.contact.publicosAddress!.eip55With0x));
    }

    final inboxId = widget.contact.registeredInboxIDs?.firstOrNull?.inboxId;
    if (inboxId != null) {
      contactInfo.writeln(l10n.floatingContactMenuShareInboxLabel(inboxId));
    }

    Share.share(
      contactInfo.toString(),
      subject:
          l10n.floatingContactMenuShareContactLabel(widget.contact.displayName),
    );
  }

  void _deleteContact(BuildContext context) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          constraints: const BoxConstraints(minWidth: DialogWidth.min, maxWidth: DialogWidth.s),
          title: Text(context.l10n.floatingContactMenuDeleteTitle),
          content: Text(context.l10n
              .floatingContactMenuDeleteConfirm(widget.contact.displayName)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.l10n.dlgCancel),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                widget.onDelete?.call();
              },
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              child: Text(context.l10n.floatingContactMenuDelete),
            ),
          ],
        );
      },
    );
  }

  void _dismiss() {
    _animationController.reverse().then((_) {
      widget.onDismiss?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    const menuWidth = 160.0;
    const menuHeight = 100.0; // 48px x 2 items + 1px divider

    // Calculate position to keep menu on screen
    final screenSize = MediaQuery.of(context).size;
    final safePosition = Offset(
      (widget.position.dx - menuWidth / 2).clamp(16.0, screenSize.width - menuWidth - 16.0),
      (widget.position.dy - menuHeight / 2).clamp(16.0, screenSize.height - menuHeight - 16.0),
    );

    return Positioned(
      left: safePosition.dx,
      top: safePosition.dy,
      child: AnimatedBuilder(
        animation: _animationController,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: Opacity(
              opacity: _fadeAnimation.value,
              child: Material(
                elevation: 0,
                borderRadius: BorderRadius.circular(PhigitalStyle.radiusCard),
                child: Container(
                  width: menuWidth,
                  height: menuHeight,
                  decoration: BoxDecoration(
                    color: PhigitalStyle.cardBackground(isDark),
                    borderRadius: BorderRadius.circular(PhigitalStyle.radiusCard),
                    border: Border.all(
                      color: PhigitalStyle.cardBorder(isDark),
                      width: 1,
                    ),
                    boxShadow: PhigitalStyle.cardShadow(isDark),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildMenuItem(
                        icon: Icons.share,
                        label: context.l10n.floatingContactMenuShare,
                        color: ThemeProvider.tealPrimary,
                        onTap: () {
                          _dismiss();
                          _shareContact(context);
                        },
                      ),
                      Container(
                        height: 1,
                        margin: const EdgeInsets.symmetric(horizontal: 12),
                        color: PhigitalStyle.subtleBorder(isDark),
                      ),
                      _buildMenuItem(
                        icon: Icons.delete,
                        label: context.l10n.floatingContactMenuDelete,
                        color: theme.colorScheme.error,
                        onTap: () {
                          _dismiss();
                          _deleteContact(context);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
