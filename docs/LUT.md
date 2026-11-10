# Using a LUT with Muon (WGSL)

## Why a PNG atlas?

Horizon's shader API deliberately gives a pack no file I/O: a pack is a folder
or a zip with WGSL, a manifest, and up to eight PNG textures. A `.cube` LUT
therefore cannot be read at runtime. Muon (WGSL) bakes a 3D LUT into a **2D atlas PNG**
that the final pass samples with trilinear filtering.

The atlas layout is deliberately simple:

```
width  = 33 * 33 = 1089 px
height = 33 px
slice b (blue) occupies columns b*33 .. b*33+32
inside a slice: x = red, y = green
```

33 samples per axis is the classic photographic LUT size and is what the
shader's `MU_LUT_SIZE` expects. The converter resamples larger LUTs down to 33³.

The LUT is **display-referred**: it is applied after tone mapping, just before
dithering and output. That is the space a Lightroom/Resolve display LUT expects.

## 1. Export a 3D LUT

- **DaVinci Resolve**: Color page → LUT → Export, choose a `.cube` (3D).
- **Affinity Photo**: File → Export LUT.
- **Lightroom Classic** does not export `.cube` directly; use a LUT-export
  plugin or round-trip through Resolve/Affinity.
- Any other tool that writes a standard 3D `.cube` is fine.

If the LUT expects log footage, convert/apply it to a display-referred image
first; Muon (WGSL) applies the LUT to display-encoded SDR values.

## 2. Convert the `.cube`

From the repository root:

```sh
python tools/cube_to_lut_png.py my_look.cube pack/lut.png
```

The converter prints the source size and the atlas size. If the result looks
red/blue swapped in game, the exporter used the other data order; run:

```sh
python tools/cube_to_lut_png.py my_look.cube pack/lut.png --blue-fastest
```

## 3. Repack or hot-reload

**Release bundle (one step):** the `muon-download` release contains the built
shader and the converter. `--pack` replaces the atlas inside the `.hshader`
directly, so no unzip/rezip is needed:

```sh
python cube_to_lut_png.py my_look.cube lut.png --pack muon-0.5.1.hshader
```

Copy the rewritten `.hshader` into `shaderpacks/` and reload the pack.

**Zip install from the repository:**

```sh
python tools/pack_muon.py pack muon-0.5.1.hshader
```

Copy the new `.hshader` over the old one in `shaderpacks/` and reload the pack.

**Folder install (best for LUT iteration):** copy `pack/` to
`shaderpacks/muon/` and select it. Horizon watches the folder; replacing
`lut.png` is picked up within about half a second, no repack needed.

## 4. Enable it in game

Shader Options → **Use LUT** on, then set **LUT strength**. It is off by
default, so the shipped identity atlas cannot alter the image until you opt in.

## Identity LUT

`pack/lut.png` is a neutral identity atlas. To regenerate it:

```sh
cd pack
python ../tools/make_identity_lut.py
```

## Notes

- The atlas is sampled with linear filtering and clamp wrapping. Keep it exactly
  1089×33; the converter does this for you.
- LUT strength 0 is bypass; 0.5 blends halfway between graded and LUT output.
- HDR output still applies the LUT to the display-encoded image, so the same LUT
  behaves consistently in SDR and HDR.
- If the LUT makes the image unexpectedly dark, check whether it was authored
  for scene-linear/log input rather than display sRGB; Muon (WGSL) applies it in
  display space.
