import 'package:flutter/material.dart';
import 'package:publicos_client/theme/glass_theme.dart';

/// The "weight" of an action a dialog/sheet is asking the user to take, shown
/// as a small standardized leading icon so the user can tell at a glance what
/// kind of commitment this is:
///
///  - [regular]     — a normal in-app action, no chain commitment → NO icon.
///  - [signature]   — the user signs a message / consent / typed-data / claim
///                    (proves identity, no funds move) → teal pen badge.
///  - [transaction] — broadcasts an on-chain transaction (state changes, may
///                    cost gas / move funds, harder to undo) → amber bolt badge.
///
/// One shared vocabulary across every confirm surface. Drop an
/// [ActionLevelBadge] at the start of a dialog/sheet header.
enum ActionLevel { regular, signature, transaction }

class ActionLevelBadge extends StatelessWidget {
  final ActionLevel level;
  final double size;

  const ActionLevelBadge(this.level, {super.key, this.size = 30});

  static IconData? iconFor(ActionLevel level) {
    switch (level) {
      case ActionLevel.regular:
        return null;
      case ActionLevel.signature:
        return Icons.draw_rounded;
      case ActionLevel.transaction:
        return Icons.bolt_rounded;
    }
  }

  static Color accentFor(ActionLevel level, GlassTokens tokens) {
    switch (level) {
      case ActionLevel.transaction:
        return tokens.fallbackAccent; // heavier — moves state/funds
      case ActionLevel.signature:
      case ActionLevel.regular:
        return tokens.connectedAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    final icon = iconFor(level);
    if (icon == null) return const SizedBox.shrink();
    final tokens = GlassTokens.of(context);
    final accent = accentFor(level, tokens);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: accent.withValues(alpha: 0.4)),
      ),
      child: Icon(icon, size: size * 0.55, color: accent),
    );
  }
}
