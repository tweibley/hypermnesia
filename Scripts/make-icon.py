#!/usr/bin/env python3
"""Turn the full-bleed source art into a macOS AppIcon.icns.

The source (packaging/icon/AppIcon-source.png, a 1024x1024 full-bleed render) is
masked into the Apple "squircle" (a superellipse, not a plain rounded rect),
inset with the standard icon-grid margin, given a soft contact shadow, then
rendered out to every size iconutil expects and packed into AppIcon.icns.

Usage:  python3 Scripts/make-icon.py
Deps:   Pillow, numpy, and `iconutil` (ships with macOS).
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ICON_DIR = ROOT / "packaging" / "icon"
SOURCE = ICON_DIR / "AppIcon-source.png"
ICNS = ICON_DIR / "AppIcon.icns"

CANVAS = 1024          # full icon canvas
BODY = 824             # Apple icon-grid body size within the 1024 canvas
SUPERELLIPSE_N = 5.0   # ~Apple squircle curvature
SS = 4                 # supersample factor for crisp antialiased edges

# iconutil iconset filenames -> pixel size
ICONSET = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def squircle_mask(size: int, n: float) -> Image.Image:
    """8-bit alpha mask of a centered superellipse filling `size`x`size`."""
    hi = size * SS
    coords = (np.arange(hi) + 0.5) / hi * 2.0 - 1.0  # -1..1 across the axis
    x = np.abs(coords)[None, :]
    y = np.abs(coords)[:, None]
    inside = (x ** n + y ** n) <= 1.0
    mask = Image.fromarray((inside * 255).astype("uint8"), mode="L")
    return mask.resize((size, size), Image.LANCZOS)


def build_master() -> Image.Image:
    art = Image.open(SOURCE).convert("RGB").resize((BODY, BODY), Image.LANCZOS)
    body = art.convert("RGBA")
    body.putalpha(squircle_mask(BODY, SUPERELLIPSE_N))

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - BODY) // 2

    # Soft contact shadow: the body silhouette, darkened, blurred, nudged down.
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    silhouette = Image.new("RGBA", (BODY, BODY), (0, 0, 0, 130))
    silhouette.putalpha(Image.eval(body.getchannel("A"), lambda a: int(a * 0.5)))
    shadow.paste(silhouette, (offset, offset + int(CANVAS * 0.012)), silhouette)
    shadow = shadow.filter(ImageFilter.GaussianBlur(CANVAS * 0.02))

    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(body, (offset, offset))
    return canvas


def main() -> int:
    if not SOURCE.exists():
        print(f"error: missing source art at {SOURCE}", file=sys.stderr)
        return 1

    master = build_master()
    master.save(ICON_DIR / "AppIcon-1024.png")

    iconset = ICON_DIR / "AppIcon.iconset"
    if iconset.exists():
        for f in iconset.iterdir():
            f.unlink()
    iconset.mkdir(exist_ok=True)
    for name, px in ICONSET.items():
        master.resize((px, px), Image.LANCZOS).save(iconset / name)

    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(ICNS)], check=True
    )
    print(f"wrote {ICNS.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
