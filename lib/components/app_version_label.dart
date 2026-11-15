import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:publicos_client/theme/glass_theme.dart';

/// Small dim `vX.Y.Z+N` label showing the running build's version.
///
/// Reads `PackageInfo.fromPlatform()` — the version is baked into the
/// installed package at build time from `pubspec.yaml`, so this always
/// reflects the actual build the user is on (debug APK, Play track, etc.)
/// with zero hardcoding. `package_info_plus` caches the platform read, so
/// rendering this on multiple screens costs one lookup.
class AppVersionLabel extends StatelessWidget {
  const AppVersionLabel({super.key});

  static Future<PackageInfo>? _infoFuture;

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.of(context);
    _infoFuture ??= PackageInfo.fromPlatform();
    return FutureBuilder<PackageInfo>(
      future: _infoFuture,
      builder: (context, snapshot) {
        final info = snapshot.data;
        if (info == null) return const SizedBox.shrink();
        return Text(
          'v${info.version}+${info.buildNumber}',
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            color: tokens.textDim,
          ),
        );
      },
    );
  }
}
