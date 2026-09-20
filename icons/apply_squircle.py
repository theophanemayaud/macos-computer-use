#!/usr/bin/env python3
"""Cut Apple-style squircle corners so Finder shows a rounded app icon."""

import sys

from PIL import Image, ImageDraw, ImageFilter


def squircle_mask(size: int) -> Image.Image:
    # macOS / iOS icon continuous corners are ~22.4% of the edge.
    radius = int(round(size * 0.224))
    hi = size * 2
    mask = Image.new("L", (hi, hi), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, hi - 1, hi - 1), radius=radius * 2, fill=255
    )
    mask = mask.resize((size, size), Image.Resampling.LANCZOS)
    return mask.filter(ImageFilter.GaussianBlur(0.4))


def main() -> None:
    src, dst = sys.argv[1], sys.argv[2]
    image = Image.open(src).convert("RGBA").resize((1024, 1024), Image.Resampling.LANCZOS)
    image.putalpha(squircle_mask(1024))
    image.save(dst, "PNG")


if __name__ == "__main__":
    main()
