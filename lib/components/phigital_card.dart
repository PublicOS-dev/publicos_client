import 'package:flutter/material.dart';
import 'package:publicos_client/providers/theme_provider.dart';

/// Phigital ID-badge style card with header icon, title, optional badge,
/// content children, and an optional action bar at the bottom.
class PhigitalCard extends StatelessWidget {
  final ThemeData theme;
  final bool isDark;
  final IconData icon;
  final String title;
  final List<Widget> children;
  final Widget? actionBar;
  final String? badge;
  final Color? badgeColor;

  const PhigitalCard({
    super.key,
    required this.theme,
    required this.isDark,
    required this.icon,
    required this.title,
    required this.children,
    this.actionBar,
    this.badge,
    this.badgeColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: PhigitalStyle.cardBackground(isDark),
        borderRadius: BorderRadius.circular(PhigitalStyle.radiusCard),
        border: Border.all(color: PhigitalStyle.cardBorder(isDark), width: 1),
        boxShadow: PhigitalStyle.cardShadow(isDark),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(PhigitalStyle.radiusCard - 1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: ThemeProvider.tealPrimary.withValues(alpha: isDark ? 0.2 : 0.12),
                      borderRadius: BorderRadius.circular(PhigitalStyle.radiusButton),
                    ),
                    child: Icon(
                      icon,
                      color: ThemeProvider.tealPrimary,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                  if (badge != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: (badgeColor ?? ThemeProvider.tealPrimary).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        badge!,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: badgeColor ?? ThemeProvider.tealPrimary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Content
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
            // Action bar
            if (actionBar != null) actionBar!,
          ],
        ),
      ),
    );
  }
}

/// Toggle row inside a PhigitalCard: icon, title, description, and Switch.
class PhigitalToggle extends StatelessWidget {
  final ThemeData theme;
  final bool isDark;
  final String title;
  final String description;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;

  const PhigitalToggle({
    super.key,
    required this.theme,
    required this.isDark,
    required this.title,
    required this.description,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PhigitalStyle.subtleTint(isDark),
        borderRadius: BorderRadius.circular(10),
        border: value
            ? Border.all(color: ThemeProvider.tealPrimary.withValues(alpha: 0.4), width: 1)
            : null,
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: value
                  ? ThemeProvider.tealPrimary.withValues(alpha: 0.15)
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(PhigitalStyle.radiusButton),
            ),
            child: Icon(
              icon,
              size: 16,
              color: value
                  ? ThemeProvider.tealPrimary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Transform.scale(
            scale: 0.8,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeColor: ThemeProvider.tealPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Key-value info row for PhigitalCard content areas.
class PhigitalInfoRow extends StatelessWidget {
  final ThemeData theme;
  final bool isDark;
  final String label;
  final String value;
  final String? copyValue;
  final VoidCallback? onCopy;

  const PhigitalInfoRow({
    super.key,
    required this.theme,
    required this.isDark,
    required this.label,
    required this.value,
    this.copyValue,
    this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: copyValue != null
                ? GestureDetector(
                    onTap: onCopy,
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            value,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.copy_rounded,
                          size: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  )
                : Text(
                    value,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Action bar at the bottom of a PhigitalCard.
class PhigitalActionBar extends StatelessWidget {
  final ThemeData theme;
  final bool isDark;
  final List<PhigitalAction> actions;
  final Widget? trailingAction;

  const PhigitalActionBar({
    super.key,
    required this.theme,
    required this.isDark,
    required this.actions,
    this.trailingAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: PhigitalStyle.subtleTint(isDark),
        border: Border(
          top: BorderSide(color: PhigitalStyle.subtleBorder(isDark)),
        ),
      ),
      child: Row(
        children: [
          ...actions.map((action) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _PhigitalActionButton(theme: theme, isDark: isDark, action: action),
              )),
          if (trailingAction != null) ...[
            const Spacer(),
            trailingAction!,
          ],
        ],
      ),
    );
  }
}

class _PhigitalActionButton extends StatelessWidget {
  final ThemeData theme;
  final bool isDark;
  final PhigitalAction action;

  const _PhigitalActionButton({
    required this.theme,
    required this.isDark,
    required this.action,
  });

  @override
  Widget build(BuildContext context) {
    final color = action.isDestructive
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;

    return GestureDetector(
      onTap: action.onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: action.isDestructive
              ? theme.colorScheme.error.withValues(alpha: 0.1)
              : PhigitalStyle.subtleTint(isDark),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(action.icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(
              action.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Data class for PhigitalActionBar buttons.
class PhigitalAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;

  const PhigitalAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });
}
