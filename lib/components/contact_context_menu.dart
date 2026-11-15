import 'package:publicos_core/publicos_core.dart';
import 'package:flutter/material.dart';
import 'package:publicos_client/components/floating_contact_menu.dart';

/// Overlay controller for floating contact menu
class ContactContextMenu {
  static OverlayEntry? _currentOverlay;

  static void show({
    required BuildContext context,
    required Contact contact,
    required Offset position,
    VoidCallback? onDelete,
  }) {
    // Remove any existing overlay
    hide();

    _currentOverlay = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // Transparent backdrop to catch taps and dismiss
          Positioned.fill(
            child: GestureDetector(
              onTap: hide,
              child: Container(
                color: Colors.transparent,
              ),
            ),
          ),
          // Floating menu
          FloatingContactMenu(
            contact: contact,
            position: position,
            onDelete: () {
              hide();
              onDelete?.call();
            },
            onDismiss: hide,
          ),
        ],
      ),
    );

    Overlay.of(context).insert(_currentOverlay!);
  }

  static void hide() {
    _currentOverlay?.remove();
    _currentOverlay = null;
  }
}