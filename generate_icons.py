"""
App Icon Generator for PublicOS Client
Generates all required icon sizes for Android, iOS, Windows, macOS, and Web.

Design: Phigital logo - large rounded square with smaller rounded square (moon)
above it. Matches PhigitalLoadingWidget static pose (moon at 12 o'clock).

Centering rule: frame_center = (moon_top + main_bottom) / 2
This visually balances the two-element composition in the icon frame.

Colors: Civic Modernism palette
  Background: slateDarkest (#1e2328)
  Foreground: light gray (#cccccc)
"""

from PIL import Image, ImageDraw
import json
import os
import sys

# Colors
FG_COLOR = (204, 204, 204)       # Light gray shapes
BG_COLOR = (30, 35, 40)          # slateDarkest
SHADOW_COLOR = (20, 24, 28)      # Darker shadow


# Proportions from PhigitalLoadingWidget
# Main square: size x size, borderRadius = size * 0.42
# Moon: size * 0.375, borderRadius = moonSize * 0.44
# Orbit offset: size * 0.875 (distance from center to moon center)
# Centering shift: (orbit_offset + moon_size/2 - main_size/2) / 2


def draw_rounded_rect(draw, x, y, w, h, radius, fill):
    """Draw a rounded rectangle using ellipses and rectangles."""
    r = min(radius, w // 2, h // 2)
    draw.ellipse([x, y, x + 2*r, y + 2*r], fill=fill)
    draw.ellipse([x + w - 2*r, y, x + w, y + 2*r], fill=fill)
    draw.ellipse([x, y + h - 2*r, x + 2*r, y + h], fill=fill)
    draw.ellipse([x + w - 2*r, y + h - 2*r, x + w, y + h], fill=fill)
    draw.rectangle([x + r, y, x + w - r, y + h], fill=fill)
    draw.rectangle([x, y + r, x + w, y + h - r], fill=fill)


def draw_phigital_mark(draw, center_x, center_y, size, fg_color, shadow_color=None):
    """
    Draw the phigital mark (main square + moon) centered according to the
    centering rule: frame_center = (moon_top + main_bottom) / 2.
    """
    main_w = size
    main_h = size
    main_radius = size * 0.42
    orbit_size = size * 0.375
    orbit_radius = orbit_size * 0.44
    orbit_offset = size * 0.875

    # Centering rule shift
    centering_shift = (orbit_offset + orbit_size / 2 - main_h / 2) / 2

    # Main square position
    main_x = center_x - main_w / 2
    main_y = center_y - main_h / 2 + centering_shift

    # Moon position (top, -pi/2)
    orbit_center_x = center_x
    orbit_center_y = center_y - orbit_offset + centering_shift
    orbit_x = orbit_center_x - orbit_size / 2
    orbit_y = orbit_center_y - orbit_size / 2

    shadow_offset = max(1, int(size * 0.0625))

    # Draw shadows first
    if shadow_color:
        draw_rounded_rect(draw,
                          int(main_x), int(main_y + shadow_offset),
                          int(main_w), int(main_h),
                          int(main_radius), shadow_color)
        draw_rounded_rect(draw,
                          int(orbit_x), int(orbit_y + shadow_offset),
                          int(orbit_size), int(orbit_size),
                          int(orbit_radius), shadow_color)

    # Draw shapes
    draw_rounded_rect(draw,
                      int(main_x), int(main_y),
                      int(main_w), int(main_h),
                      int(main_radius), fg_color)
    draw_rounded_rect(draw,
                      int(orbit_x), int(orbit_y),
                      int(orbit_size), int(orbit_size),
                      int(orbit_radius), fg_color)


def draw_icon_with_bg(canvas_size, padding_ratio=0.12):
    """Draw the icon on a dark background at the specified size."""
    img = Image.new("RGB", (canvas_size, canvas_size), BG_COLOR)
    draw = ImageDraw.Draw(img)

    effective_canvas = canvas_size * (1 - 2 * padding_ratio)
    size = effective_canvas / 2.01
    center = canvas_size / 2

    draw_phigital_mark(draw, center, center, size, FG_COLOR, SHADOW_COLOR)
    return img


def draw_foreground_layer(canvas_size):
    """
    Draw the Android adaptive icon foreground layer.
    Adaptive icons use a 108dp canvas with the icon in the inner 72dp (66%).
    The outer area may be masked by the launcher.
    """
    img = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Inner safe zone is 66.67% of canvas
    safe_zone = canvas_size * 0.6667
    size = safe_zone / 2.01
    center = canvas_size / 2

    draw_phigital_mark(draw, center, center, size, FG_COLOR, SHADOW_COLOR)
    return img


def draw_background_layer(canvas_size):
    """Draw the Android adaptive icon background layer (solid color)."""
    return Image.new("RGB", (canvas_size, canvas_size), BG_COLOR)


# ── Android ────────────────────────────────────────────────────────────────

ANDROID_DENSITIES = {
    "mdpi":    1.0,
    "hdpi":    1.5,
    "xhdpi":   2.0,
    "xxhdpi":  3.0,
    "xxxhdpi": 4.0,
}

def generate_android_icons(base_path):
    """Generate Android launcher icons (legacy + adaptive layers)."""
    print("\n=== Android Icons ===")
    res_path = os.path.join(base_path, "android", "app", "src", "main", "res")

    for density, scale in ANDROID_DENSITIES.items():
        folder = os.path.join(res_path, f"mipmap-{density}")
        os.makedirs(folder, exist_ok=True)

        # Legacy icon: 48dp base
        legacy_size = int(48 * scale)
        legacy = draw_icon_with_bg(legacy_size, padding_ratio=0.10)
        legacy.save(os.path.join(folder, "ic_launcher.png"), "PNG")

        # Adaptive layers: 108dp base
        adaptive_size = int(108 * scale)
        fg = draw_foreground_layer(adaptive_size)
        fg.save(os.path.join(folder, "ic_launcher_foreground.png"), "PNG")

        bg = draw_background_layer(adaptive_size)
        bg.save(os.path.join(folder, "ic_launcher_background.png"), "PNG")

        print(f"  {density}: legacy {legacy_size}px, adaptive {adaptive_size}px")


# ── iOS ────────────────────────────────────────────────────────────────────

IOS_ICON_SPECS = [
    # (base_size, scale, idiom)  ->  pixel_size = base_size * scale
    (20, 1, "ipad"),
    (20, 2, "iphone"),
    (20, 2, "ipad"),
    (20, 3, "iphone"),
    (29, 1, "iphone"),
    (29, 1, "ipad"),
    (29, 2, "iphone"),
    (29, 2, "ipad"),
    (29, 3, "iphone"),
    (40, 1, "ipad"),
    (40, 2, "iphone"),
    (40, 2, "ipad"),
    (40, 3, "iphone"),
    (60, 2, "iphone"),
    (60, 3, "iphone"),
    (76, 1, "ipad"),
    (76, 2, "ipad"),
    (83.5, 2, "ipad"),
    (1024, 1, "ios-marketing"),
]

def generate_ios_icons(base_path):
    """Generate iOS app icon set."""
    print("\n=== iOS Icons ===")
    assets_path = os.path.join(base_path, "ios", "Runner", "Assets.xcassets",
                               "AppIcon.appiconset")
    os.makedirs(assets_path, exist_ok=True)

    # Collect unique pixel sizes to avoid redundant rendering
    rendered = {}
    images_json = []

    for base_size, scale, idiom in IOS_ICON_SPECS:
        pixel_size = int(base_size * scale)

        # Filename pattern
        if base_size == int(base_size):
            size_str = f"{int(base_size)}x{int(base_size)}"
        else:
            size_str = f"{base_size}x{base_size}"

        if scale == 1:
            filename = f"Icon-App-{size_str}@1x.png"
        else:
            filename = f"Icon-App-{size_str}@{scale}x.png"

        if pixel_size not in rendered:
            img = draw_icon_with_bg(pixel_size, padding_ratio=0.10)
            rendered[pixel_size] = img

        rendered[pixel_size].save(os.path.join(assets_path, filename), "PNG")

        images_json.append({
            "size": size_str,
            "idiom": idiom,
            "filename": filename,
            "scale": f"{scale}x",
        })

    # Write Contents.json
    contents = {
        "images": images_json,
        "info": {"version": 1, "author": "generate_icons.py"}
    }
    with open(os.path.join(assets_path, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)

    print(f"  {len(rendered)} unique sizes, {len(images_json)} entries in Contents.json")


# ── Windows ────────────────────────────────────────────────────────────────

def generate_windows_icon(base_path):
    """Generate Windows .ico with multiple sizes."""
    print("\n=== Windows Icon ===")
    sizes = [16, 32, 48, 64, 128, 256]
    images = {}

    for size in sizes:
        images[size] = draw_icon_with_bg(size, padding_ratio=0.12)

    ico_path = os.path.join(base_path, "windows", "runner", "resources", "app_icon.ico")
    os.makedirs(os.path.dirname(ico_path), exist_ok=True)
    images[256].save(ico_path, format="ICO", sizes=[(s, s) for s in sizes])
    print(f"  -> {ico_path}")


# ── macOS ──────────────────────────────────────────────────────────────────

def generate_macos_icons(base_path):
    """Generate macOS app icon set."""
    print("\n=== macOS Icons ===")
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    assets_path = os.path.join(base_path, "macos", "Runner", "Assets.xcassets",
                               "AppIcon.appiconset")
    os.makedirs(assets_path, exist_ok=True)

    for size in sizes:
        img = draw_icon_with_bg(size, padding_ratio=0.10)
        img.save(os.path.join(assets_path, f"app_icon_{size}.png"), "PNG")

    # Contents.json
    specs = [
        {"size": "16x16",   "scale": "1x", "filename": "app_icon_16.png"},
        {"size": "16x16",   "scale": "2x", "filename": "app_icon_32.png"},
        {"size": "32x32",   "scale": "1x", "filename": "app_icon_32.png"},
        {"size": "32x32",   "scale": "2x", "filename": "app_icon_64.png"},
        {"size": "128x128", "scale": "1x", "filename": "app_icon_128.png"},
        {"size": "128x128", "scale": "2x", "filename": "app_icon_256.png"},
        {"size": "256x256", "scale": "1x", "filename": "app_icon_256.png"},
        {"size": "256x256", "scale": "2x", "filename": "app_icon_512.png"},
        {"size": "512x512", "scale": "1x", "filename": "app_icon_512.png"},
        {"size": "512x512", "scale": "2x", "filename": "app_icon_1024.png"},
    ]

    contents = {
        "images": [{"size": s["size"], "idiom": "mac",
                     "filename": s["filename"], "scale": s["scale"]}
                   for s in specs],
        "info": {"version": 1, "author": "generate_icons.py"}
    }
    with open(os.path.join(assets_path, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)

    print(f"  {len(sizes)} sizes generated")


# ── Web ────────────────────────────────────────────────────────────────────

def generate_web_icons(base_path):
    """Generate web favicons and PWA icons."""
    print("\n=== Web Icons ===")
    web_path = os.path.join(base_path, "web")

    # favicon.png (16x16)
    img16 = draw_icon_with_bg(16, padding_ratio=0.10)
    img16.save(os.path.join(web_path, "favicon.png"), "PNG")

    # PWA icons
    for size, filename in [(192, "Icon-192.png"), (512, "Icon-512.png"),
                           (192, "Icon-maskable-192.png"), (512, "Icon-maskable-512.png")]:
        icons_dir = os.path.join(web_path, "icons")
        os.makedirs(icons_dir, exist_ok=True)
        img = draw_icon_with_bg(size, padding_ratio=0.10)
        img.save(os.path.join(icons_dir, filename), "PNG")

    print("  favicon.png + 4 PWA icons")


# ── Main ───────────────────────────────────────────────────────────────────

def main():
    base_path = os.path.dirname(os.path.abspath(__file__))

    if "--root" in sys.argv:
        idx = sys.argv.index("--root")
        if idx + 1 >= len(sys.argv):
            print("Error: --root requires a path argument")
            sys.exit(1)
        root = sys.argv[idx + 1]
        os.makedirs(root, exist_ok=True)
        print(f"PublicOS Client Icon Generator - SAMPLE to {root}")
        img = draw_icon_with_bg(512, padding_ratio=0.10)
        out = os.path.join(root, "icon_sample_512.png")
        img.save(out, "PNG")
        print(f"  -> {out}")
        return

    if len(sys.argv) > 1 and sys.argv[1] == "test":
        print("PublicOS Client Icon Generator - TEST MODE")
        img = draw_icon_with_bg(512, padding_ratio=0.10)
        out = os.path.join(base_path, "test_icon.png")
        img.save(out, "PNG")
        print(f"  -> {out}")
        return

    print("PublicOS Client Icon Generator")
    print("=" * 50)
    print(f"Design: Phigital logo with centering rule")
    print(f"Background: {BG_COLOR}")
    print(f"Foreground: {FG_COLOR}")

    generate_android_icons(base_path)
    generate_ios_icons(base_path)
    generate_windows_icon(base_path)
    generate_macos_icons(base_path)
    generate_web_icons(base_path)

    print("\n" + "=" * 50)
    print("Icon generation complete!")


if __name__ == "__main__":
    main()
