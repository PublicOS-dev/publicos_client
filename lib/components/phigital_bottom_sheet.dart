import 'package:flutter/material.dart';
import 'package:publicos_client/providers/theme_provider.dart';

/// Shows a bottom sheet styled with the phigital design system:
/// - Transparent scaffold background (decoration owns the color)
/// - Card background color, top radius 20, hard upward shadow
/// - Handle bar (36x4)
/// - Safe area bottom padding
/// - Optional keyboard-aware inset padding
///
/// [builder] receives the sheet context and the resolved [isDark] flag.
/// If [useDraggable] is true, wraps content in a [DraggableScrollableSheet].
Future<T?> showPhigitalBottomSheet<T>({
  required BuildContext context,
  required Widget Function(BuildContext context, bool isDark) builder,
  bool useDraggable = false,
  double initialChildSize = 0.5,
  double minChildSize = 0.25,
  double maxChildSize = 0.9,
  bool enableDrag = true,
  bool isDismissible = true,
  bool showHandle = true,
  /// When false, skips the legacy phigital card chrome (background +
  /// border + handle) so the sheet body owns its own visuals. Keyboard
  /// inset + bottom safe-area are still applied. Use this for glass-themed
  /// sheets that paint their own background.
  bool wrapInChrome = true,
  RouteSettings? routeSettings,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    enableDrag: enableDrag,
    isDismissible: isDismissible,
    routeSettings: routeSettings,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      final isDark = theme.brightness == Brightness.dark;
      final bottomPadding = MediaQuery.of(sheetContext).viewInsets.bottom;

      Widget wrap(BuildContext ctx, Widget child) {
        if (wrapInChrome) {
          return _PhigitalSheetChrome(
            isDark: isDark,
            bottomPadding: bottomPadding,
            showHandle: showHandle,
            child: child,
          );
        }
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomPadding),
            child: child,
          ),
        );
      }

      if (useDraggable) {
        return DraggableScrollableSheet(
          initialChildSize: initialChildSize,
          minChildSize: minChildSize,
          maxChildSize: maxChildSize,
          builder: (dragContext, scrollController) {
            return wrap(dragContext, builder(dragContext, isDark));
          },
        );
      }

      return wrap(sheetContext, builder(sheetContext, isDark));
    },
  );
}

class _PhigitalSheetChrome extends StatelessWidget {
  final bool isDark;
  final double bottomPadding;
  final Widget child;
  final bool showHandle;

  const _PhigitalSheetChrome({
    required this.isDark,
    required this.bottomPadding,
    required this.child,
    this.showHandle = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: PhigitalStyle.sheetDecoration(isDark),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showHandle) PhigitalStyle.handleBar(isDark),
              Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }
}
