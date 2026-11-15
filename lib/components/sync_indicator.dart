import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'package:publicos_client/providers/theme_provider.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';

/// A compact sync indicator that shows chain sync status.
///
/// States:
/// - Syncing: Shows animated orbit (like PhigitalLoadingWidget but smaller)
/// - Failed: Shows cloud-off icon
/// - Success: Shows nothing (hidden)
class SyncIndicator extends StatefulWidget {
  final bool isSyncing;
  final bool hasFailed;
  final double size;
  final VoidCallback? onRetry;

  const SyncIndicator({
    super.key,
    required this.isSyncing,
    required this.hasFailed,
    this.size = 20,
    this.onRetry,
  });

  @override
  State<SyncIndicator> createState() => _SyncIndicatorState();
}

class _SyncIndicatorState extends State<SyncIndicator>
    with TickerProviderStateMixin {
  late AnimationController _orbitController;

  @override
  void initState() {
    super.initState();
    _orbitController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );

    if (widget.isSyncing) {
      _orbitController.repeat();
    }
  }

  @override
  void didUpdateWidget(SyncIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSyncing != oldWidget.isSyncing) {
      if (widget.isSyncing) {
        _orbitController.repeat();
      } else {
        _orbitController.stop();
      }
    }
  }

  @override
  void dispose() {
    _orbitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Show nothing if not syncing and hasn't failed
    if (!widget.isSyncing && !widget.hasFailed) {
      return const SizedBox.shrink();
    }

    // Show cloud-off icon if sync failed
    if (widget.hasFailed && !widget.isSyncing) {
      return GestureDetector(
        onTap: widget.onRetry,
        child: Tooltip(
          message: context.l10n.syncIndicatorSyncFailedRetry,
          child: Container(
            width: widget.size + 4,
            height: widget.size + 4,
            decoration: BoxDecoration(
              color: ThemeProvider.amberAccent.withValues(alpha:0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              Icons.cloud_off_rounded,
              size: widget.size - 4,
              color: ThemeProvider.amberAccent,
            ),
          ),
        ),
      );
    }

    // Show orbit animation while syncing
    return AnimatedBuilder(
      animation: _orbitController,
      builder: (context, child) {
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Main circle
              Container(
                width: widget.size * 0.45,
                height: widget.size * 0.45,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.onSurface.withValues(alpha:0.7),
                ),
              ),
              // Orbiting smaller circle
              Transform.rotate(
                angle: _orbitController.value * 2 * math.pi,
                child: Transform.translate(
                  offset: Offset(widget.size * 0.35, 0),
                  child: Container(
                    width: widget.size * 0.2,
                    height: widget.size * 0.2,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.colorScheme.onSurface.withValues(alpha:0.7),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
