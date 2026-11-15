import 'package:publicos_core/publicos_core.dart';
import 'package:flutter/material.dart';
import 'package:publicos_client/components/glass_contact_icon.dart';
class DraggableContactIcon extends StatelessWidget {
  final Contact contact;
  final double size;
  final double textSize;
  final VoidCallback? onTap;
  final bool isSelected;
  final VoidCallback? onToggle;

  const DraggableContactIcon({
    super.key,
    required this.contact,
    this.size = 64,
    this.textSize = 14,
    this.onTap,
    this.isSelected = false,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    print('🔍 DEBUG: DraggableContactIcon building for ${contact.displayName}, size: $size, textSize: $textSize, isSelected: $isSelected');
    
    return GestureDetector(
      onTap: onTap ?? onToggle,
      child: Container(
        constraints: BoxConstraints(
          minHeight: size + textSize * 2, // Ensure minimum height
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: isSelected ? Border.all(
            color: Theme.of(context).primaryColor,
            width: 2,
          ) : null,
          color: isSelected ? Theme.of(context).primaryColor.withValues(alpha: 0.1) : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Fixed height for icon
            SizedBox(
              height: size,
              child: Padding(
                padding: const EdgeInsets.all(4.0),
                child: Center(
                  child: GlassContactIcon(
                    contact: contact,
                    size: size * 0.8, // Slightly smaller to account for padding
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            // Fixed height for text
            SizedBox(
              height: textSize * 1.5,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2.0),
                child: Text(
                  contact.displayName,
                  style: TextStyle(
                    fontSize: textSize,
                    color: Theme.of(context).textTheme.bodyLarge?.color,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}