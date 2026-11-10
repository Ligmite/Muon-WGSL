#!/usr/bin/env python3
"""Convert a 3D .cube LUT (Lightroom / DaVinci Resolve / etc.) to Muon (WGSL)'s
2D atlas PNG.

Usage:
    python cube_to_lut_png.py input.cube output.png [--blue-fastest]
    python cube_to_lut_png.py input.cube output.png --pack muon-0.5.1.hshader

With --pack, the atlas is also written into a copy of the `.hshader` (the
download bundle ships that file next to this tool), replacing its `lut.png`.
Horizon reads a `.hshader` as a zip, so this avoids unpacking and repacking by
hand.

The .cube spec's usual data order is red-fastest:
    index = b*N*N + g*N + r
Some exporters write blue-fastest instead; pass --blue-fastest if red and blue
look swapped in game.

The output is a 33^3 atlas resampled to the layout Muon (WGSL) expects:
    width 33*33, height 33, slice b at x=b*33, inner x=red, y=green.
Muon (WGSL)'s shader uses a fixed 33^3 atlas, so larger LUTs are resampled.

Values are written as display-referred 8-bit sRGB, the space a photographic
LUT normally expects. Apply at strength < 1 with the pack's LUT strength option.
"""
from __future__ import annotations

import argparse
import os
import sys
import zipfile
from pathlib import Path

from PIL import Image

N = 33


def parse_cube(path: str):
    size = None
    domain_min = (0.0, 0.0, 0.0)
    domain_max = (1.0, 1.0, 1.0)
    data = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            key = parts[0].upper()
            if key == "LUT_3D_SIZE":
                size = int(parts[1])
            elif key == "LUT_1D_SIZE":
                raise SystemExit("1D LUTs are not supported; export a 3D .cube")
            elif key == "DOMAIN_MIN":
                domain_min = tuple(float(v) for v in parts[1:4])
            elif key == "DOMAIN_MAX":
                domain_max = tuple(float(v) for v in parts[1:4])
            elif key in ("TITLE", "LUT_3D_INPUT_RANGE"):
                continue
            else:
                try:
                    r, g, b = (float(v) for v in parts[:3])
                    data.append((r, g, b))
                except ValueError:
                    continue
    if size is None:
        raise SystemExit("no LUT_3D_SIZE in .cube")
    if len(data) != size ** 3:
        raise SystemExit(f"expected {size**3} entries, found {len(data)}")
    return size, domain_min, domain_max, data


def norm(v: float, lo: float, hi: float) -> float:
    return 0.0 if hi == lo else max(0.0, min(1.0, (v - lo) / (hi - lo)))


def sample(data, size, r, g, b, blue_fastest):
    # nearest-neighbour resample of the source lattice to the target 33^3
    r = max(0.0, min(1.0, r)) * (size - 1)
    g = max(0.0, min(1.0, g)) * (size - 1)
    b = max(0.0, min(1.0, b)) * (size - 1)
    ri, gi, bi = round(r), round(g), round(b)
    if blue_fastest:
        idx = ri * size * size + gi * size + bi
    else:
        idx = bi * size * size + gi * size + ri
    return data[idx]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cube")
    ap.add_argument("png")
    ap.add_argument("--blue-fastest", action="store_true")
    ap.add_argument("--pack", metavar="HSHADER",
                    help="also replace lut.png inside this .hshader")
    args = ap.parse_args()

    size, dmin, dmax, data = parse_cube(args.cube)
    img = Image.new("RGB", (N * N, N))
    px = img.load()
    for b in range(N):
        for g in range(N):
            for r in range(N):
                rr = r / (N - 1)
                gg = g / (N - 1)
                bb = b / (N - 1)
                v = sample(data, size, rr, gg, bb, args.blue_fastest)
                v = (norm(v[0], dmin[0], dmax[0]),
                     norm(v[1], dmin[1], dmax[1]),
                     norm(v[2], dmin[2], dmax[2]))
                px[b * N + r, g] = tuple(round(max(0.0, min(1.0, c)) * 255) for c in v)
    img.save(args.png, optimize=True)
    print(f"wrote {args.png}: {size}^3 -> {N}^3 atlas ({N*N}x{N})")

    if args.pack:
        pack = Path(args.pack)
        if not pack.is_file():
            raise SystemExit(f"no such pack: {pack}")
        atlas = Path(args.png).read_bytes()
        tmp = pack.with_name(pack.name + ".lut-tmp")
        replaced = False
        with zipfile.ZipFile(pack) as src, \
                zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as dst:
            for item in src.infolist():
                data = src.read(item.filename)
                if item.filename == "lut.png":
                    data = atlas
                    replaced = True
                dst.writestr(item, data)
        if not replaced:
            os.remove(tmp)
            raise SystemExit(f"{pack} has no lut.png")
        os.replace(tmp, pack)
        print(f"packed {args.png} into {pack}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
