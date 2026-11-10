#!/usr/bin/env python3
"""Write an identity 33x33x33 LUT as a 2D atlas PNG.

Layout (what muon's mu_apply_lut samples):
    width  = 33 * 33 = 1089 px
    height = 33 px
    slice b (blue) occupies columns b*33 .. b*33+32
    inside a slice, column = red, row = green

The atlas is display-referred: pixel values are the identity mapping of sRGB
input to sRGB output, so a pack with this file and lut_strength 1 is unchanged.
"""
from PIL import Image

N = 33
w, h = N * N, N
img = Image.new("RGB", (w, h))
px = img.load()
for b in range(N):
    for g in range(N):
        for r in range(N):
            px[b * N + r, g] = (
                round(r * 255 / (N - 1)),
                round(g * 255 / (N - 1)),
                round(b * 255 / (N - 1)),
            )

img.save("lut.png", optimize=True)
print(f"wrote lut.png ({w}x{h}, {N}^3 identity)")
