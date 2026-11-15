import 'package:flutter/material.dart';
import 'package:publicos_client/components/phigital_loading_widget.dart';
import 'package:publicos_client/theme/glass_theme.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/l10n/boot_phase.dart';
import 'package:publicos_client/widgets/error/error_l10n.dart';

class InitializationScreen extends StatelessWidget {
  final String? loadingMessage;
  final String? errorMessage;
  final VoidCallback? onRetry;

  const InitializationScreen({
    super.key,
    this.loadingMessage,
    this.errorMessage,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    final l10n = context.l10n;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF0F0F0F),
                    tokens.background,
                  ],
                  center: Alignment.center,
                  radius: 1.5,
                ),
              ),
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PhigitalLoadingWidget(
                  rotate: errorMessage == null,
                  size: 48,
                  color: errorMessage == null
                      ? null
                      : Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 48),
                if (errorMessage != null)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 40),
                    padding: const EdgeInsets.all(16),
                    decoration: GlassTheme.glassBox(context).copyWith(
                      border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .error
                            .withValues(alpha: 0.5),
                      ),
                    ),
                    child: Text(
                      bootErrorLabel(l10n, errorMessage) ??
                          localizedError(l10n, errorMessage),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  )
                else if (loadingMessage != null)
                  Text(
                    bootPhaseLabel(l10n, loadingMessage) ?? '',
                    style: TextStyle(
                      color: tokens.textDim,
                      fontSize: 14,
                      letterSpacing: 2,
                    ),
                  ),
                const SizedBox(height: 32),
                if (errorMessage != null && onRetry != null)
                  TextButton.icon(
                    onPressed: onRetry,
                    icon: Icon(Icons.refresh,
                        color: Theme.of(context).colorScheme.error),
                    label: Text(
                      l10n.bootRetry,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        letterSpacing: 2,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 16),
                      backgroundColor:
                          Colors.white.withValues(alpha: 0.05),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
