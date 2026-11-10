#!/usr/bin/env python3
"""Generate a tileable grayscale water-noise texture (256x256, RGB PNG).

Muon (WGSL) samples this in the material stage for the phase noise of its wave
octaves. Value noise is built on periodic lattices so the PNG tiles seamlessly
under wrap = "repeat".
"""
from __future__ import annotations

import numpy as np
from PIL import Image

SIZE = 256
rng = np.random.default_rng(0x4D554F4E)  # "MUON"


def periodic_noise(n: int, grid: int, rng) -> np.ndarray:
    g = rng.random((grid, grid), dtype=np.float32)
    x = np.arange(n, dtype=np.float32) * (grid / n)
    i0 = np.floor(x).astype(np.int32) % grid
    i1 = (i0 + 1) % grid
    f = x - np.floor(x)
    u = f * f * (3.0 - 2.0 * f)
    a = g[np.ix_(i0, i0)]
    b = g[np.ix_(i0, i1)]
    c = g[np.ix_(i1, i0)]
    d = g[np.ix_(i1, i1)]
    ux = u[:, None]
    uy = u[None, :]
    return (a * (1 - ux) + b * ux) * (1 - uy) + (c * (1 - ux) + d * ux) * uy


acc = np.zeros((SIZE, SIZE), dtype=np.float32)
amp = 0.55
norm = 0.0
for grid in (8, 16, 32, 64, 128):
    acc += periodic_noise(SIZE, grid, rng) * amp
    norm += amp
    amp *= 0.55
acc /= norm
acc = np.clip(acc, 0.0, 1.0)
img = Image.fromarray(np.round(acc * 255).astype(np.uint8), "L").convert("RGB")
img.save("water_noise.png", optimize=True)
print("wrote water_noise.png (256x256 tileable)")
