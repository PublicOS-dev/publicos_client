import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Save [bytes] where the user chooses, through the OS save dialog
/// (Android: the system "create document" picker; iOS: the Files picker).
/// The dialog IS the permission grant, and file_picker writes the bytes itself
/// on mobile. Returns the saved path/URI, or null when the user cancels.
/// Throws on a write failure. Desktop twin: publicos_desktop utils/save_file.dart.
Future<String?> saveBytesWithDialog({
  required Uint8List bytes,
  required String filename,
}) {
  // Same leaf-name rule as open_file.dart: no path separators or illegal chars.
  final safe = filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  return FilePicker.saveFile(fileName: safe, bytes: bytes);
}
