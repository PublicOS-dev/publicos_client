import 'package:flutter/material.dart';

import 'package:publicos_client/theme/glass_theme.dart';

/// Shared chrome for the system-app pages launched from the Apps grid
/// (Treasury / Account Center / Settings / Nodes / BSP / SSP). Provides:
///
///  - `Scaffold` + transparent `AppBar` + back button (pops via
///    `Navigator.pop` so iOS swipe-back + Android back both work)
///  - Icon pill + title in the AppBar (pinned via `pinHeader: true`, the
///    canonical mode for system-app pages — title lives in the AppBar at
///    full opacity, no big body header)
///
/// Usage:
///
/// ```dart
/// SystemAppScaffold(
///   title: 'Nodes',
///   icon: Icons.hub_rounded,
///   pinHeader: true,
///   builder: (context, scrollController, tokens) {
///     return ListView(
///       controller: scrollController,
///       children: [
///         SizedBox(height: kToolbarHeight + 60),
///         // sections — use local _sectionHeader(tokens, icon, title)
///         // helper, no outer card.
///       ],
///     );
///   },
/// )
/// ```
///
/// The page owns its body widget (typically `ListView` or `CustomScrollView`)
/// and must attach the provided `ScrollController`.
class SystemAppScaffold extends StatefulWidget {
  final String title;
  final IconData icon;

  /// Optional bundled art (`assets/system_apps/*.png`, Fluent style) shown in
  /// place of [icon] — the picture the Apps tile (and the desktop rail) already
  /// shows for this page, so the place you clicked and the page you land on read as one
  /// thing (both apps). [icon] stays the decode-failure fallback
  /// and the glyph for pages with no art (Nodes).
  final String? asset;
  final Widget Function(
    BuildContext context,
    ScrollController scrollController,
    GlassTokens tokens,
  ) builder;

  /// Optional trailing widgets shown in the AppBar (refresh / overflow / etc.)
  final List<Widget>? actions;

  /// When true, the AppBar shows icon + title at full opacity always (no
  /// scroll fade). Caller is expected to omit [SystemAppHeader] from the
  /// body since the title is already visible in the AppBar.
  final bool pinHeader;

  const SystemAppScaffold({
    super.key,
    required this.title,
    required this.icon,
    this.asset,
    required this.builder,
    this.actions,
    this.pinHeader = false,
  });

  @override
  State<SystemAppScaffold> createState() => _SystemAppScaffoldState();
}

class _SystemAppScaffoldState extends State<SystemAppScaffold> {
  final ScrollController _scrollController = ScrollController();

  /// 0 = big title fully visible (and compact title hidden)
  /// 1 = big title scrolled past (compact title fully in header)
  double _headerProgress = 0.0;

  static const double _fadeStart = 40;
  static const double _fadeEnd = 100;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final offset = _scrollController.offset;
    final next = ((offset - _fadeStart) / (_fadeEnd - _fadeStart))
        .clamp(0.0, 1.0);
    if ((next - _headerProgress).abs() > 0.01) {
      setState(() => _headerProgress = next);
    }
  }

  /// [SystemAppScaffold.asset] at [size], rounded like the rail's art
  /// (radius 9 at 28 px), or [fallback] when there is no art or it fails to
  /// decode.
  Widget _headerArt(double size, Widget fallback) {
    final asset = widget.asset;
    if (asset == null) return fallback;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 9 / 28),
      child: Image.asset(
        asset,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * dpr).round(),
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final pinned = widget.pinHeader;
    final progress = pinned ? 1.0 : _headerProgress;
    final accent = tokens.connectedAccent;
    return Scaffold(
      backgroundColor: tokens.background,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: tokens.background.withValues(
          alpha: pinned ? 0.85 : progress * 0.85,
        ),
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
          color: tokens.starkWhite,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: pinned
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _headerArt(
                    28,
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: tokens.glassFill,
                        border: Border.all(
                          color: accent.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Icon(widget.icon, color: accent, size: 16),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    widget.title,
                    style: TextStyle(
                      color: tokens.starkWhite,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              )
            : Opacity(
                opacity: progress,
                child: Transform.translate(
                  offset: Offset(0, (1 - progress) * 12),
                  child: Text(
                    widget.title,
                    style: TextStyle(
                      color: tokens.starkWhite,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              ),
        centerTitle: true,
        actions: widget.actions,
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: widget.builder(context, _scrollController, tokens),
      ),
    );
  }
}

/// Primary action button — glassFill + borderMedium + 12pt w800 letterSpacing 2
/// label.
class SystemAppActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  /// Optional tier colour: a tinted fill with the label and icon
  /// in that colour, for actions that must not look like the others — the
  /// Account app's renounce (softDanger) and delete-all-records
  /// (fallbackAccent). Null = the standard glass button.
  final Color? accent;

  const SystemAppActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final disabled = onTap == null;
    if (disabled) {
      // System-wide disabled style:
      // no fill, dashed border, dim text/icon. The dashed border is the
      // load-bearing signal that the affordance is unavailable.
      final disabledColor = tokens.textDim.withValues(alpha: 0.55);
      return SizedBox(
        width: double.infinity,
        child: CustomPaint(
          painter: DashedRRectPainter(
            color: tokens.borderSubtle,
            radius: 10,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16, color: disabledColor),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                    fontSize: 12,
                    color: disabledColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent?.withValues(alpha: 0.12) ?? tokens.glassFill,
          foregroundColor: accent ?? tokens.starkWhite,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: accent?.withValues(alpha: 0.5) ?? tokens.borderMedium),
          ),
        ),
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

/// Paints a dashed rounded-rectangle stroke around the painter's size.
/// Used as the visual cue for disabled action buttons (see
/// [SystemAppActionButton]) and any other affordance that reads as
/// "not currently available." Keeps the click target the same shape as
/// the enabled button so layout doesn't shift between states.
class DashedRRectPainter extends CustomPainter {
  const DashedRRectPainter({
    required this.color,
    this.radius = 10,
  });

  final Color color;
  final double radius;
  static const double dashWidth = 6;
  static const double dashGap = 4;
  static const double strokeWidth = 1;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    // Inset by half the stroke so the border sits cleanly inside size.
    const inset = strokeWidth / 2;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        inset,
        inset,
        size.width - strokeWidth,
        size.height - strokeWidth,
      ),
      Radius.circular(radius),
    );
    final source = Path()..addRRect(rrect);

    final dashed = Path();
    for (final metric in source.computeMetrics()) {
      double distance = 0;
      bool draw = true;
      while (distance < metric.length) {
        final next = distance + (draw ? dashWidth : dashGap);
        if (draw) {
          dashed.addPath(
            metric.extractPath(distance, next.clamp(0, metric.length)),
            Offset.zero,
          );
        }
        distance = next;
        draw = !draw;
      }
    }
    canvas.drawPath(dashed, paint);
  }

  @override
  bool shouldRepaint(DashedRRectPainter old) =>
      old.color != color || old.radius != radius;
}
