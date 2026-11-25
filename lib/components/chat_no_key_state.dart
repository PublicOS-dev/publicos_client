// ChatNoKeyState — what a chat tab shows when no XMTP inbox is loaded.
//
// The chat screen itself is NOT built in this state: it resolves a DM topic
// against the loaded inbox, and with none it threw (a red error on desktop).
// The whole tile is the action: it opens the keychain, where the sim button
// loads a key. The host swaps this for the chat once an inbox is loaded.

import 'package:flutter/material.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';
import 'package:publicos_client/theme/glass_theme.dart';

class ChatNoKeyState extends StatelessWidget {
  final VoidCallback onLoadKeys;

  const ChatNoKeyState({super.key, required this.onLoadKeys});

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    return Center(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onLoadKeys,
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sim_card_outlined, size: 64, color: tokens.textDim),
              const SizedBox(height: 20),
              Text(
                context.l10n.chatNoKeyTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'SpaceGrotesk',
                  color: tokens.starkWhite,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
