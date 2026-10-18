#!/usr/bin/env python3
"""Draws nanomon's app icon, a small cell graph in Codegraff colors (amber
over rust on warm charcoal), and writes AppIcon.icns beside this file.
Needs Pillow and macOS's iconutil. Usage: python3 macos/make-icon.py"""
import os, subprocess, tempfile
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
S = 1024

def base():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Apple's icon grid: an 824-point square, corners of about 185.
    box = (100, 100, 924, 924)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, 185, fill=255)
    fill = Image.new("RGBA", (S, S))
    fd = ImageDraw.Draw(fill)
    top, bottom = (0x2a, 0x26, 0x1e), (0x16, 0x14, 0x0f)
    for y in range(S):
        t = min(1, max(0, (y - 100) / 824))
        fd.line([(0, y), (S, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    img.paste(fill, (0, 0), mask)
    d.rounded_rectangle(box, 185, outline=(0x3a, 0x35, 0x2b, 255), width=4)
    return img, d

def draw(d):
    amber, rust, empty = (0xe8, 0xa3, 0x3d, 255), (0xd2, 0x67, 0x4f, 255), (0x2c, 0x28, 0x20, 255)
    cols, rows, cell, gap = 7, 7, 62, 18
    x0 = (S - (cols * cell + (cols - 1) * gap)) // 2
    y0 = (S - (rows * cell + (rows - 1) * gap)) // 2 + 20
    # Busy cells from the bottom: system below, user above.
    heights = [(1, 1), (1, 2), (2, 2), (1, 4), (2, 3), (2, 5), (1, 3)]
    for c, (sys, user) in enumerate(heights):
        for r in range(rows):
            level = rows - 1 - r
            color = rust if level < sys else amber if level < sys + user else empty
            x, y = x0 + c * (cell + gap), y0 + r * (cell + gap)
            d.rounded_rectangle((x, y, x + cell, y + cell), 12, fill=color)

def icns(img, name):
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.mkdir(iconset)
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = size * scale
                suffix = "" if scale == 1 else "@2x"
                img.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}{suffix}.png"))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(HERE, name)], check=True)

if __name__ == "__main__":
    img, d = base()
    draw(d)
    img.save(os.path.join(tempfile.gettempdir(), "nanomon-icon.png"))
    icns(img, "AppIcon.icns")
