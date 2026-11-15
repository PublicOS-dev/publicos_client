import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:publicos_client/widgets/media_overlay.dart';

/// Backwards-compatibility shim around [MediaOverlay] for the image-only
/// callers. Prefer `MediaOverlay` directly in new code.
class ImageOverlay extends StatelessWidget {
  final String? imageUrl;
  final Uint8List? imageData;
  final String heroTag;
  final VoidCallback onClose;

  const ImageOverlay({
    super.key,
    this.imageUrl,
    this.imageData,
    required this.heroTag,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return MediaOverlay(
      imageUrl: imageUrl,
      imageData: imageData,
      heroTag: heroTag,
      onClose: onClose,
    );
  }
}
