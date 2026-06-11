#!/usr/bin/env python3
"""Generate the Click macOS app icon.

Design: a clear keyboard mark on an electric-blue squircle. It is optimized
to read well at small System Settings sizes, where the old keycap artwork
looked too generic.
"""

import os
from PIL import Image, ImageDraw, ImageFilter

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTDIR = os.path.join(REPO_ROOT, "Click", "Assets.xcassets", "AppIcon.appiconset")
SIZE = 1024
CORNER_RADIUS_RATIO = 0.2237

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


def squircle_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        (0, 0, size - 1, size - 1),
        radius=int(size * CORNER_RADIUS_RATIO),
        fill=255,
    )
    return mask


def vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    pixels = image.load()
    for y in range(size):
        t = y / (size - 1)
        t = t * t * (3 - 2 * t)
        color = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        for x in range(size):
            pixels[x, y] = color
    return image


def add_glow(image: Image.Image, box: tuple[int, int, int, int], color: tuple[int, int, int, int], blur: int) -> None:
    glow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow)
    draw.ellipse(box, fill=color)
    image.alpha_composite(glow.filter(ImageFilter.GaussianBlur(blur)))


def rounded_rect(draw: ImageDraw.ImageDraw, box, radius, fill, outline=None, width=1) -> None:
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def draw_keyboard(image: Image.Image) -> None:
    draw = ImageDraw.Draw(image)
    s = image.size[0]

    x0 = int(s * 0.155)
    y0 = int(s * 0.235)
    x1 = int(s * 0.845)
    y1 = int(s * 0.755)
    radius = int(s * 0.085)

    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        (x0, y0 + int(s * 0.035), x1, y1 + int(s * 0.035)),
        radius=radius,
        fill=(0, 0, 0, 95),
    )
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(int(s * 0.035))))

    rounded_rect(draw, (x0, y0, x1, y1), radius, (245, 249, 255, 255))
    rounded_rect(draw, (x0, int(y0 + (y1 - y0) * 0.62), x1, y1), radius, (214, 225, 241, 255))

    # Top highlight and lower depth line.
    draw.rounded_rectangle(
        (x0 + int(s * 0.045), y0 + int(s * 0.04), x1 - int(s * 0.045), y0 + int(s * 0.14)),
        radius=int(s * 0.035),
        fill=(255, 255, 255, 150),
    )
    draw.line(
        (x0 + int(s * 0.075), int(y0 + (y1 - y0) * 0.60), x1 - int(s * 0.075), int(y0 + (y1 - y0) * 0.60)),
        fill=(170, 187, 210, 210),
        width=max(2, int(s * 0.012)),
    )

    key_color = (22, 127, 255, 255)
    key_shadow = (5, 73, 166, 120)
    key_w = int(s * 0.064)
    key_h = int(s * 0.055)
    gap = int(s * 0.020)
    start_x = x0 + int(s * 0.115)
    row_y = [
        y0 + int(s * 0.17),
        y0 + int(s * 0.27),
        y0 + int(s * 0.37),
    ]
    row_counts = [7, 7, 6]
    row_offsets = [0, int(s * 0.035), int(s * 0.070)]

    for row, count in enumerate(row_counts):
        for col in range(count):
            kx = start_x + row_offsets[row] + col * (key_w + gap)
            ky = row_y[row]
            rounded_rect(
                draw,
                (kx, ky + int(s * 0.006), kx + key_w, ky + key_h + int(s * 0.006)),
                int(s * 0.018),
                key_shadow,
            )
            rounded_rect(draw, (kx, ky, kx + key_w, ky + key_h), int(s * 0.018), key_color)

    space_x0 = start_x + int(s * 0.11)
    space_x1 = x1 - int(s * 0.10)
    space_y0 = y0 + int(s * 0.50)
    rounded_rect(
        draw,
        (space_x0, space_y0, space_x1, space_y0 + int(s * 0.06)),
        int(s * 0.022),
        key_color,
    )

    # Small sound marks, kept inside the silhouette so they remain visible in
    # System Settings without making the icon busy.
    cx = int((x0 + x1) / 2)
    base_y = int(y0 + (y1 - y0) * 0.36)
    for i, height in enumerate([0.10, 0.15, 0.21, 0.15, 0.10]):
        bar_w = int(s * 0.018)
        bx = cx + (i - 2) * int(s * 0.045)
        bh = int(s * height)
        rounded_rect(
            draw,
            (bx, base_y - bh // 2, bx + bar_w, base_y + bh // 2),
            bar_w // 2,
            (255, 255, 255, 230),
        )


def make_master() -> Image.Image:
    image = vertical_gradient(SIZE, (16, 20, 68), (20, 130, 255))
    add_glow(image, (-180, -180, 520, 520), (170, 210, 255, 55), 80)
    add_glow(image, (520, 620, 1280, 1320), (0, 31, 118, 115), 110)
    draw_keyboard(image)

    masked = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    masked.paste(image, (0, 0), squircle_mask(SIZE))
    return masked


def main() -> None:
    os.makedirs(OUTDIR, exist_ok=True)
    master = make_master()
    for filename, size in SIZES:
        resized = master.resize((size, size), Image.LANCZOS)
        resized.save(os.path.join(OUTDIR, filename), format="PNG")
        print(f"wrote {filename} ({size}x{size})")
    print(f"all icons written under {OUTDIR}")


if __name__ == "__main__":
    main()
