import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// A widget that displays a QR code using the qr_flutter package.
class QrCodeWidget extends StatelessWidget {
  /// The data to be encoded in the QR code.
  final String data;
  
  /// The size of the widget.
  final double size;
  
  /// The color of the QR code modules.
  final Color foregroundColor;
  
  /// The background color of the widget.
  final Color backgroundColor;
  
  /// The error correction level to use for the QR code.
  final int errorCorrectLevel;

  const QrCodeWidget({
    super.key,
    required this.data,
    this.size = 200.0,
    this.foregroundColor = Colors.black,
    this.backgroundColor = Colors.white,
    this.errorCorrectLevel = QrErrorCorrectLevel.L,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      color: backgroundColor,
      child: QrImageView(
        data: data,
        version: QrVersions.auto,
        size: size,
        backgroundColor: backgroundColor,
        errorCorrectionLevel: errorCorrectLevel,
        eyeStyle: QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: foregroundColor,
        ),
        dataModuleStyle: QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: foregroundColor,
        ),
      ),
    );
  }
}