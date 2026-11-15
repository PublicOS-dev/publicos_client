import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'dart:typed_data';

/// Result of an inline-compress pass — bytes are smaller-than-or-equal to
/// the input, and `mimeType` may have shifted (e.g. heic → jpeg if the
/// underlying compressor downconverts).
class CompressedImage {
  final Uint8List bytes;
  final String mimeType;

  const CompressedImage({required this.bytes, required this.mimeType});
}

class ImageUtils {
  // Max size for inline (LOW) attachments inside the XMTP envelope.
  static const int MAX_SIZE_BYTES = 1024 * 1024;

  /// Compress image bytes for the inline-LOW path. Pure: no picker, no
  /// dialogs, no UI side-effects. Image-only — videos go through the HD
  /// path where compression doesn't apply.
  ///
  /// Returns the input untouched if already under the inline ceiling, or a
  /// progressively-quality-reduced (then resolution-reduced if still too
  /// big) version that fits.
  static Future<CompressedImage> compressForInline(
    Uint8List input,
    String mimeType,
    String filename,
  ) async {
    if (input.length <= MAX_SIZE_BYTES) {
      return CompressedImage(bytes: input, mimeType: mimeType);
    }

    final format = _formatForMime(mimeType, filename);

    // Downscale-FIRST. For a multi-megapixel photo, resolution — not quality —
    // dominates file size, so a single downscale+quality pass gets almost any
    // photo under the inline ceiling. The old quality-only loop re-decoded the
    // full-res original at EVERY step (up to ~7 passes, slow on an 8 MB image);
    // this needs ≤3 passes, usually 1. Inline is the LOW tier — full-res goes
    // out via the HD/remote path — so downscaling here is by design.
    // Each step is [quality, min-side]; FlutterImageCompress scales so the
    // shorter side ≈ min-side, keeping aspect ratio.
    const steps = [
      [88, 1280],
      [68, 1024],
      [48, 800],
    ];
    Uint8List result = input;
    for (final s in steps) {
      result = await FlutterImageCompress.compressWithList(
        input,
        quality: s[0],
        minWidth: s[1],
        minHeight: s[1],
        format: format,
      );
      if (result.length <= MAX_SIZE_BYTES) break;
    }

    // FlutterImageCompress may downconvert (heic → jpeg). Reflect that on
    // the way out so the consumer wraps the bytes in the right MIME.
    final outMime = format == CompressFormat.png
        ? 'image/png'
        : format == CompressFormat.webp
            ? 'image/webp'
            : 'image/jpeg';
    return CompressedImage(bytes: result, mimeType: outMime);
  }

  static CompressFormat _formatForMime(String mimeType, String filename) {
    final m = mimeType.toLowerCase();
    if (m == 'image/png') return CompressFormat.png;
    if (m == 'image/webp') return CompressFormat.webp;
    if (m == 'image/jpeg') return CompressFormat.jpeg;
    // MIME unknown — fall back to extension.
    final ext = filename.toLowerCase().split('.').last;
    if (ext == 'png') return CompressFormat.png;
    if (ext == 'webp') return CompressFormat.webp;
    return CompressFormat.jpeg;
  }
}
