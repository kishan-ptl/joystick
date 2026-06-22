#!/bin/zsh
# Regenerate AppIcon.icns from icon.png (the navy source artwork).
# Wraps the artwork in the native macOS squircle tile with the standard
# ~10% transparent margin so it sits like other Dock icons, then packs every
# required resolution into AppIcon.icns via iconutil.
#   ./make-icon.sh   → writes AppIcon.icns next to this script
set -e
DIR="${0:A:h}"
SRC="$DIR/icon.png"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

# Build a 1024 master (squircle-masked, padded) then downscale to each size.
python3 - "$SRC" "$ICONSET" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageCms

src_path, iconset = sys.argv[1], sys.argv[2]

# Tag every layer sRGB. Without a profile macOS renders the icon against the
# display's native (wide-gamut) space, so the dark mark looks lighter on the
# Dock than the sRGB-tagged source artwork. Embedding sRGB makes the OS
# color-manage the icon identically to the source PNG.
SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()

CANVAS = 1024          # master canvas
MARGIN = 100           # transparent margin each side (macOS icon grid)
BODY = CANVAS - 2 * MARGIN   # 824 squircle tile
N = 5.0                # superellipse exponent ≈ Apple's continuous corner
SS = 4                 # supersample factor for a clean anti-aliased edge

# Superellipse (squircle) alpha mask at BODY*SS, |x|^N + |y|^N = 1.
m = BODY * SS
mask = Image.new("L", (m, m), 0)
px = mask.load()
half = m / 2.0
for y in range(m):
    ny = abs((y + 0.5 - half) / half)
    yn = ny ** N
    for x in range(m):
        nx = abs((x + 0.5 - half) / half)
        px[x, y] = 255 if (nx ** N + yn) <= 1.0 else 0
mask = mask.resize((BODY, BODY), Image.LANCZOS)

art = Image.open(src_path).convert("RGBA").resize((BODY, BODY), Image.LANCZOS)
master = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
master.paste(art, (MARGIN, MARGIN), mask)

# Canonical macOS iconset: (pixel size, filename) at 1x and @2x.
pairs = [(16,"icon_16x16.png"),(32,"icon_16x16@2x.png"),(32,"icon_32x32.png"),
         (64,"icon_32x32@2x.png"),(128,"icon_128x128.png"),(256,"icon_128x128@2x.png"),
         (256,"icon_256x256.png"),(512,"icon_256x256@2x.png"),(512,"icon_512x512.png"),
         (1024,"icon_512x512@2x.png")]
for s, name in pairs:
    master.resize((s, s), Image.LANCZOS).save(f"{iconset}/{name}", icc_profile=SRGB)
print("iconset ready")
PY

iconutil -c icns "$ICONSET" -o "$DIR/AppIcon.icns"
echo "Wrote $DIR/AppIcon.icns"
