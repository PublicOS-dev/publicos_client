import 'package:flutter/material.dart';

enum TextureOption {
  dark,
  grey,
  white,
  darkerWhite,
  transparent,
  transparentWhiter,
  transparentColors,
  None
}

class TexturedContainer extends StatelessWidget {
  final Widget child;
  final TextureOption texture;
  final BorderRadius borderRadius;
  final EdgeInsets padding;
  final Color? color;
  final Border border;
  final Gradient? gradient;
  final BoxShadow? boxShadow;
  const TexturedContainer(
      {super.key,
      required this.child,
      required this.texture,
      this.borderRadius = BorderRadius.zero,
      this.padding = EdgeInsets.zero,
      this.border = const Border(),
      this.color,
      this.gradient,
      this.boxShadow});

  String get _backgroundImagePath {
    switch (texture) {
      case TextureOption.dark:
        return 'lib/assets/textures/dark.png';
      case TextureOption.grey:
        return 'lib/assets/textures/grey.png';
      case TextureOption.white:
        return 'lib/assets/textures/white.png';
      case TextureOption.darkerWhite:
        return 'lib/assets/textures/darkerWhite.png';
      case TextureOption.transparent:
        return 'lib/assets/textures/transparent.png';
      case TextureOption.transparentWhiter:
        return 'lib/assets/textures/transparentWhites.png';
      case TextureOption.transparentColors:
        return 'lib/assets/textures/transparentColors.png';
      case TextureOption.None:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return
        // ClipRRect(
        //   borderRadius: borderRadius,
        //   child:
        Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        color: color,
        gradient: gradient,
        boxShadow: boxShadow != null ? [boxShadow!] : null,
        image: texture != TextureOption.None
            ? DecorationImage(
                image: AssetImage(_backgroundImagePath),
                repeat: ImageRepeat.repeat,
                fit: BoxFit.none,
              )
            : null,
        border: border,
      ),
      child: child,
      // ),
    );
  }
}
