import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:publicos_client/l10n/l10n_ext.dart';

/// Switch image_picker onto the Android Photo Picker (images + videos ONLY).
/// Without this, image_picker falls back to the legacy ACTION_GET_CONTENT file
/// intent whose MIME filter some devices ignore, surfacing every file (.bin,
/// .xmtpbak, …) in the "image" chooser. Runs once; no-op off Android.
bool _photoPickerEnabled = false;
void _ensureAndroidPhotoPicker() {
  if (_photoPickerEnabled) return;
  final impl = ImagePickerPlatform.instance;
  if (impl is ImagePickerAndroid) {
    impl.useAndroidPhotoPicker = true;
  }
  _photoPickerEnabled = true;
}

/// What kinds of media the picker should surface.
enum MediaPickerKind {
  /// Image only — videos won't appear in the picker UI.
  imageOnly,

  /// Mixed images + videos. Caller must guarantee the consumer has a
  /// way to actually send/upload videos (a feed server / SSP) before
  /// using this; otherwise pass [imageOnly] so users don't see options
  /// they can't fulfill.
  imageAndVideo,
}

/// One picked item, with bytes pre-read and MIME pre-resolved.
class PickedMedia {
  final XFile file;
  final Uint8List bytes;
  final String filename;
  final String mimeType;
  final bool isVideo;

  const PickedMedia({
    required this.file,
    required this.bytes,
    required this.filename,
    required this.mimeType,
    required this.isVideo,
  });
}

/// Pure picker — picks files from the gallery, validates size + MIME,
/// returns the bytes ready for the consumer to compress/upload/send.
///
/// - `limit == 1` → single-pick (chat).
/// - `limit > 1` → multi-pick capped at `limit` (compose).
/// - `kind` controls whether videos appear in the picker UI.
/// - `maxMb` is the per-file ceiling; over-cap files are skipped with a
///   snackbar (the rest of the batch is returned).
///
/// Returns an empty list on user-cancel. Does not throw on per-file
/// validation failures — surfaces them as snackbars and continues.
Future<List<PickedMedia>> pickMedia({
  required BuildContext context,
  int limit = 1,
  double maxMb = 100,
  MediaPickerKind kind = MediaPickerKind.imageAndVideo,
}) async {
  _ensureAndroidPhotoPicker();
  final picker = ImagePicker();
  final List<XFile> picked;

  if (kind == MediaPickerKind.imageOnly) {
    if (limit == 1) {
      final one = await picker.pickImage(source: ImageSource.gallery);
      picked = one == null ? <XFile>[] : <XFile>[one];
    } else {
      picked = await picker.pickMultiImage(limit: limit);
    }
  } else {
    if (limit == 1) {
      final one = await picker.pickMedia();
      picked = one == null ? <XFile>[] : <XFile>[one];
    } else {
      picked = await picker.pickMultipleMedia(limit: limit);
    }
  }

  if (picked.isEmpty) return const [];

  // OS may ignore `limit:` on older Android / iOS — enforce client-side.
  final selected =
      picked.length > limit ? picked.sublist(0, limit) : picked;

  final maxBytes = (maxMb * 1024 * 1024).round();
  final results = <PickedMedia>[];

  for (final file in selected) {
    final bytes = await file.readAsBytes();
    if (!context.mounted) return results;

    if (bytes.length > maxBytes) {
      final sizeMb = (bytes.length / 1024 / 1024).toStringAsFixed(1);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${file.name}: too large ($sizeMb MB > '
            '${maxMb.toStringAsFixed(0)} MB)',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      continue;
    }

    final mime = _sniffMime(bytes, file.name);
    final isVideo = mime.startsWith('video/');
    final isImage = mime.startsWith('image/');

    // Belt-and-suspenders: on a device with no Photo Picker (no Play services /
    // very old Android) image_picker still falls back to the file chooser, which
    // may leak non-media files. Drop anything that isn't the media this picker
    // promised — never stage a .bin/.pdf/etc. picked from the "image" flow.
    final allowed = kind == MediaPickerKind.imageOnly ? isImage : (isImage || isVideo);
    if (!allowed) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.mediaPickerOnlyImagesVideos),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      continue;
    }

    results.add(PickedMedia(
      file: file,
      bytes: bytes,
      filename: file.name,
      mimeType: mime,
      isVideo: isVideo,
    ));
  }

  return results;
}

/// Best-effort MIME inference. Magic bytes first (jpeg/png/gif/webp/heic/heif/
/// mp4/mov), extension fallback otherwise. Returns `application/octet-stream`
/// for unknowns. Mirrors `PublicOSSsp._sniffMime` so picker decisions match
/// what the server's allow-list will see at upload time.
String _sniffMime(Uint8List bytes, String filename) {
  if (bytes.length >= 12) {
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
      return 'image/gif';
    }
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    if (bytes[4] == 0x66 &&
        bytes[5] == 0x74 &&
        bytes[6] == 0x79 &&
        bytes[7] == 0x70) {
      final brand = String.fromCharCodes(bytes.sublist(8, 12));
      if (brand == 'heic' ||
          brand == 'heix' ||
          brand == 'mif1' ||
          brand == 'msf1') {
        return 'image/heic';
      }
      if (brand == 'mp42' || brand == 'isom' || brand == 'qt  ') {
        return 'video/mp4';
      }
    }
  }
  final ext = filename.toLowerCase().split('.').last;
  const extMap = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'heic': 'image/heic',
    'heif': 'image/heic',
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'webm': 'video/webm',
    'm4v': 'video/x-m4v',
  };
  return extMap[ext] ?? 'application/octet-stream';
}
