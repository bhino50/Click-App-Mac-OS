#!/usr/bin/env python3
"""Generate the Click macOS app icon (all 10 sizes) into AppIcon.appiconset.

Design: a tilted 3D mechanical keycap on a deep electric-blue squircle, with
a soft "click" ripple arc emanating from the keycap. Aesthetic, not template.
"""

import os
import math
from PIL import Image, ImageDraw, ImageFilter

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTDIR = os.path.join(REPO_ROOT, "Click", "Assets.xcassets", "AppIcon.appiconset")

# Master render size. All shipped sizes are downsampled with LANCZOS.
SIZE = 1024

# macOS Big Sur+ icon mask is a superellipse with a corner radius of
# ~22.37% of the icon size. We approximate with a rounded rectangle that
# uses the same continuous-curvature corner via PIL's rounded_rectangle.
CORNER_RADIUS_RATIO = 0.2237


def squircle_mask(size: int) -> Image.Image:
    r = int(size * CORNER_RADIUS_RATIO)
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle((0, 0, size - 1, size - 1), radius=r, fill=255)
    return mask


def vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    px = img.load()
    for y in range(size):
        t = y / (size - 1)
        # Smoothstep
        t = t * t * (3 - 2 * t)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        for x in range(size):
            px[x, y] = (r, g, b, 255)
    return img


def add_corner_glow(img: Image.Image, center, radius_ratio=0.20,
                    color=(255, 255, 255, 60),
                    blur_ratio=0.10) -> Image.Image:
    """Adds a soft radial highlight at `center` (fractional coords)."""
    s = img.size[0]
    glow = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(glow)
    cx, cy = int(center[0] * s), int(center[1] * s)
    r = int(s * radius_ratio)
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(radius=s * blur_ratio))
    tint = Image.new("RGBA", (s, s), color)
    return Image.composite(tint, img, glow)


def draw_keycap(img: Image.Image):
    s = img.size[0]
    cap_w = int(s * 0.54)
    cap_h_total = int(s * 0.52)            # full body including front skirt
    cap_top_h = int(s * 0.40)              # top surface height
    cap_x = (s - cap_w) // 2
    cap_y = int(s * 0.27)
    cap_radius = int(cap_w * 0.16)

    # Outer drop shadow under the cap
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        (cap_x - int(s * 0.01),
         cap_y + int(s * 0.06),
         cap_x + cap_w + int(s * 0.01),
         cap_y + cap_h_total + int(s * 0.045)),
        radius=cap_radius + int(s * 0.012),
        fill=(0, 0, 0, 150),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=s * 0.025))
    img.alpha_composite(shadow)

    # Keycap front face (darker, gives depth)
    front = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    fd = ImageDraw.Draw(front)
    fd.rounded_rectangle(
        (cap_x, cap_y + int(cap_top_h * 0.55),
         cap_x + cap_w, cap_y + cap_h_total),
        radius=cap_radius,
        fill=(196, 204, 218, 255),
    )
    img.alpha_composite(front)

    # Side gradient on the front face (left lighter, right darker)
    side_grad = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    sgd = ImageDraw.Draw(side_grad)
    for i in range(cap_w):
        t = i / cap_w
        alpha = int(45 * abs(t - 0.5) * 2)
        col = (0, 0, 0, alpha)
        sgd.rectangle(
            (cap_x + i, cap_y + int(cap_top_h * 0.55),
             cap_x + i + 1, cap_y + cap_h_total),
            fill=col,
        )
    side_mask = Image.new("L", (s, s), 0)
    smd = ImageDraw.Draw(side_mask)
    smd.rounded_rectangle(
        (cap_x, cap_y + int(cap_top_h * 0.55),
         cap_x + cap_w, cap_y + cap_h_total),
        radius=cap_radius, fill=255,
    )
    img.paste(side_grad, (0, 0), side_mask)

    # Keycap top surface (lighter, inset)
    top_inset = int(cap_w * 0.07)
    top_x0 = cap_x + top_inset
    top_y0 = cap_y
    top_x1 = cap_x + cap_w - top_inset
    top_y1 = cap_y + cap_top_h
    top = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    td = ImageDraw.Draw(top)
    td.rounded_rectangle(
        (top_x0, top_y0, top_x1, top_y1),
        radius=int(cap_radius * 0.9),
        fill=(252, 253, 255, 255),
    )
    img.alpha_composite(top)

    # Subtle top gradient (specular highlight running across the top)
    top_grad = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    tgd = ImageDraw.Draw(top_grad)
    for j in range(top_y1 - top_y0):
        t = j / max(1, (top_y1 - top_y0))
        # Highlight near top → mid-gray near bottom edge of top surface
        if t < 0.4:
            alpha = int(60 * (1 - t / 0.4))
            col = (255, 255, 255, alpha)
        else:
            tt = (t - 0.4) / 0.6
            alpha = int(40 * tt)
            col = (0, 0, 0, alpha)
        tgd.rectangle((top_x0, top_y0 + j, top_x1, top_y0 + j + 1), fill=col)
    grad_mask = Image.new("L", (s, s), 0)
    gmd = ImageDraw.Draw(grad_mask)
    gmd.rounded_rectangle(
        (top_x0, top_y0, top_x1, top_y1),
        radius=int(cap_radius * 0.9), fill=255,
    )
    img.paste(top_grad, (0, 0), grad_mask)

    # Glyph in the centre of the top surface: a "·" / dot key,
    # rendered as a soft rounded rectangle to read as a primary key.
    glyph_w = int(cap_w * 0.18)
    glyph_h = int(glyph_w * 0.55)
    gcx = (top_x0 + top_x1) // 2
    gcy = (top_y0 + top_y1) // 2
    gd = ImageDraw.Draw(img)
    # Soft shadow under glyph
    sh = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    shd = ImageDraw.Draw(sh)
    shd.rounded_rectangle(
        (gcx - glyph_w // 2, gcy - glyph_h // 2 + int(s * 0.004),
         gcx + glyph_w // 2, gcy + glyph_h // 2 + int(s * 0.004)),
        radius=glyph_h // 2,
        fill=(0, 0, 0, 50),
    )
    sh = sh.filter(ImageFilter.GaussianBlur(radius=s * 0.004))
    img.alpha_composite(sh)
    gd.rounded_rectangle(
        (gcx - glyph_w // 2, gcy - glyph_h // 2,
         gcx + glyph_w // 2, gcy + glyph_h // 2),
        radius=glyph_h // 2,
        fill=(34, 50, 80, 235),
    )

    return (gcx, top_y0, top_x1 - top_x0)


def draw_ripples(img: Image.Image, origin, _cap_width):
    """Concentric arcs emerging upward from the keycap top, suggesting sound."""
    s = img.size[0]
    cx, cy = origin
    ripple = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ripple)
    for radius, alpha, width_ratio in [
        (int(s * 0.10), 235, 0.013),
        (int(s * 0.16), 175, 0.011),
        (int(s * 0.22), 115, 0.009),
    ]:
        rd.arc(
            (cx - radius, cy - radius, cx + radius, cy + radius),
            start=205, end=335,
            fill=(255, 255, 255, alpha),
            width=max(2, int(s * width_ratio)),
        )
    ripple = ripple.filter(ImageFilter.GaussianBlur(radius=s * 0.003))
    img.alpha_composite(ripple)


def make_master() -> Image.Image:
    s = SIZE
    # Background: rich indigo → electric cobalt gradient. Stays dark enough
    # that the white keycap and ripples read with strong contrast.
    bg = vertical_gradient(s, top=(18, 22, 58), bottom=(36, 76, 200))
    # Very subtle highlight in upper-left — gives the squircle dimensionality
    # without bleaching the palette.
    bg = add_corner_glow(bg, center=(0.22, 0.16),
                         radius_ratio=0.15, color=(140, 175, 255, 45),
                         blur_ratio=0.07)
    # Soft vignette in the lower-right corner for depth.
    bg = add_corner_glow(bg, center=(0.92, 0.96),
                         radius_ratio=0.22, color=(6, 8, 24, 90),
                         blur_ratio=0.10)

    img = bg.copy()
    glyph_origin = draw_keycap(img)
    # Ripples emanate from the top-centre of the keycap.
    draw_ripples(img, (glyph_origin[0], glyph_origin[1] - int(s * 0.005)),
                 glyph_origin[2])

    # Apply the squircle mask so corners are properly rounded.
    masked = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    masked.paste(img, (0, 0), squircle_mask(s))
    return masked


SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    master = make_master()
    for filename, size in SIZES:
        out = master.resize((size, size), Image.LANCZOS)
        out.save(os.path.join(OUTDIR, filename), format="PNG")
        print(f"wrote {filename} ({size}x{size})")
    print(f"all icons written under {OUTDIR}")


if __name__ == "__main__":
    main()
