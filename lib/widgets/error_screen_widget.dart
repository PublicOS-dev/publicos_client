import 'package:flutter/material.dart';
import 'package:publicos_client/providers/theme_provider.dart';

class ErrorScreenWidget extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const ErrorScreenWidget({
    Key? key,
    required this.message,
    this.onRetry,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Error icon with Phigital container
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: theme.colorScheme.error.withValues(alpha: isDark ? 0.15 : 0.1),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: isDark
                      ? Colors.black.withValues(alpha: 0.3)
                      : ThemeProvider.slateDarkest.withValues(alpha: 0.06),
                  offset: const Offset(0, 3),
                  blurRadius: 0,
                ),
              ],
            ),
            child: Icon(
              Icons.error_outline_rounded,
              size: 40,
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 24),
          // Error message with monospace "terminal" style
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark
                  ? PhigitalStyle.surfaceDeepDark
                  : PhigitalStyle.cardBackgroundDark,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: isDark
                      ? Colors.black.withValues(alpha: 0.4)
                      : ThemeProvider.slateDarkest.withValues(alpha: 0.08),
                  offset: const Offset(0, 2),
                  blurRadius: 0,
                ),
              ],
            ),
            child: Text(
              '> $message',
              textAlign: TextAlign.left,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: ThemeProvider.successDark, // Terminal green
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 28),
          // Retry button with Phigital styling
          if (onRetry != null)
            GestureDetector(
              onTap: onRetry,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 28),
                decoration: BoxDecoration(
                  color: PhigitalStyle.cardBackground(isDark),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: theme.colorScheme.error.withValues(alpha: 0.4),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: isDark
                          ? Colors.black.withValues(alpha: 0.25)
                          : ThemeProvider.slateDarkest.withValues(alpha: 0.05),
                      offset: const Offset(0, 3),
                      blurRadius: 0,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.refresh_rounded,
                      size: 18,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Retry',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
