import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Hand-rolled "open with" — no third-party plugin. Writes [bytes] to a temp
/// file under the app cache and asks the OS to hand it to the user's chosen app
/// (Android: ACTION_VIEW via FileProvider; iOS: UIDocumentInteractionController).
///
/// The native handler is registered in MainActivity.kt / AppDelegate.swift on
/// the `com.publicos/openfile` channel. Returns true if the OS presented an
/// opener, false on any failure (no handler app, write error, channel missing).
const MethodChannel _channel = MethodChannel('com.publicos/openfile');

Future<bool> openFileWithSystem({
  required Uint8List bytes,
  required String filename,
  String? mimeType,
}) async {
  try {
    final dir = await getTemporaryDirectory();
    // Strip path separators / illegal chars so the cached name is a safe leaf.
    final safe = filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final file = File('${dir.path}/shared_docs/$safe');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);

    final ok = await _channel.invokeMethod<bool>('openFile', {
      'path': file.path,
      'mimeType': mimeType ?? 'application/octet-stream',
    });
    return ok ?? false;
  } catch (_) {
    return false;
  }
}
