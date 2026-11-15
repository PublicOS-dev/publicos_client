import 'package:flutter/material.dart';

import 'package:publicos_client/theme/glass_theme.dart';

/// Pill-shaped filter/action chip used across all explorer views.
///
/// Visual rules:
/// - Inactive: transparent fill, no border, dim text.
/// - Active: elevated-surface fill, no border, stark-white text + bolder weight.
/// - [accentColor] (when non-null) overrides foreground with a tinted
///   variant — used for action chips that should stand out regardless of [active]
///   ("Register"), or for inactive chips that are the primary CTA ("No key").
/// - [count] renders a small glass-fill badge after the label.
/// - [trailing] is appended at the end of the row (used by wallet's Group chip
///   to render a loading spinner).
class ExplorerChip extends StatelessWidget {
  final String label;

  /// The glyph before the label. Optional: a chip whose
  /// mark is a WIDGET rather than an [IconData] — a chain's brand SVG, say
  /// — passes [leading] instead, and passing both is a no-op for this one.
  final IconData? icon;

  /// Rendered in place of [icon] when given. Mirrors [trailing].
  final Widget? leading;
  final bool active;
  final int? count;
  final Color? accentColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  const ExplorerChip({
    super.key,
    required this.label,
    this.icon,
    this.leading,
    required this.active,
    this.count,
    this.accentColor,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final fg = accentColor ?? (active ? tokens.starkWhite : tokens.textDim);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? tokens.surfaceElevated : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: 6),
            ] else if (icon != null) ...[
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              overflow: TextOverflow.visible,
              style: TextStyle(
                fontFamily: 'SpaceGrotesk',
                color: fg,
                fontSize: 12,
                height: 1.3,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                letterSpacing: 0.3,
              ),
            ),
            if (count != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: tokens.glassFill,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    color: fg,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
            if (trailing != null) ...[
              const SizedBox(width: 6),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Horizontal ListView wrapper with leading/trailing fade gradients that
/// hint at off-screen chips. Fades the appropriate edge to the page
/// background whenever the scroll position has hidden content past it.
class ExplorerChipBar extends StatefulWidget {
  final List<Widget> children;
  final EdgeInsets padding;
  final double height;
  final double fadeWidth;
  final Color? fadeColor;

  const ExplorerChipBar({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    this.height = 48,
    this.fadeWidth = 28,
    this.fadeColor,
  });

  @override
  State<ExplorerChipBar> createState() => _ExplorerChipBarState();
}

class _ExplorerChipBarState extends State<ExplorerChipBar> {
  final ScrollController _ctrl = ScrollController();
  bool _showStart = false;
  bool _showEnd = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_recompute);
    WidgetsBinding.instance.addPostFrameCallback((_) => _recompute());
  }

  @override
  void dispose() {
    _ctrl.removeListener(_recompute);
    _ctrl.dispose();
    super.dispose();
  }

  void _recompute() {
    if (!_ctrl.hasClients) return;
    final p = _ctrl.position;
    final showStart = p.pixels > 0.5;
    final showEnd = p.pixels < p.maxScrollExtent - 0.5;
    if (showStart != _showStart || showEnd != _showEnd) {
      setState(() {
        _showStart = showStart;
        _showEnd = showEnd;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final fadeColor =
        widget.fadeColor ?? GlassTokens.of(context).surfaceElevated;
    final transparent = fadeColor.withValues(alpha: 0);
    return SizedBox(
      height: widget.height,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _recompute());
          return false;
        },
        child: Stack(
          children: [
            ListView(
              controller: _ctrl,
              scrollDirection: Axis.horizontal,
              padding: widget.padding,
              children: widget.children,
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: _showStart ? 1 : 0,
                  child: Container(
                    width: widget.fadeWidth,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [fadeColor, transparent],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: _showEnd ? 1 : 0,
                  child: Container(
                    width: widget.fadeWidth,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerRight,
                        end: Alignment.centerLeft,
                        colors: [fadeColor, transparent],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
