# Muon (WGSL) 0.5.1

**Muon (WGSL)** is an independent WGSL shader for Horizon's shader API 0.1 (sky +
material + weather + post), made in the spirit of SixthSurge's Photon. Muon (WGSL)'s
grade keeps the shape of Photon's `c19_color_grading` (Lottes default, 18% grey
log-contrast, hue-band saturation, split tone, vignette) and its HDR path keeps
the filmic toe with a soft shoulder at the display peak.

## What changed in 0.5.1

* **The pack is named Muon (WGSL).** The plain Muon name is being kept free for
  the planned Minecraft shader. The internal pack id (`muon`), the `MU_`
  constants and the `mu_` functions are unchanged, so existing option files and
  installs keep working.
* **Warmer, more vibrant vegetation.** Less blue in the terrain ambient, a
  warmer ground bounce, green saturation and hue pushed toward yellow, and a
  warmer split-tone.
* **The sky no longer rotates against the world on foot.** The sky stage now
  undoes Horizon's view-bob/nausea pose, which is applied to terrain and post
  passes but not to the engine's sky pass.
* **Softer water reflections.** A distance-scaled 3x3 mirror filter and a lower
  default Fresnel cap stop reflected land from looking like a second copy of
  the world.
* **Warmer distance fog.** The in-scatter is nudged warm so distant grass does
  not turn cyan.
* **Underwater stays at the 0.5.0 look.** The experimental light-shaft work was
  removed.

## What changed in 0.5.0

* **Three cloud layers.** Cumulus/stratocumulus at about 1000 blocks,
  altocumulus/altostratus at about 2800 and a planar cirrus/cirrostratus sheet at
  about 5600. Each layer has its own coverage chart, shape field and lighting;
  rain grows the cumulus into a storm deck and suppresses the cirrus. The layers
  are high and world-anchored, so walking no longer slides the whole deck across
  the sky.
* **Water reaches the horizon.** The wave field is now five octaves plus a
  crossing swell train, filtered by pixel footprint instead of distance. Long
  swells survive to the far shore; short ripples fade before they alias. The
  normal fades to a floor at grazing angles, so the lake is never a perfect
  mirror.
* **The horizon reflection is Muon (WGSL)'s sky.** Horizon's water mirror contains
  vanilla's sky gradient. Water now replaces those mirror pixels with Muon (WGSL)'s
  atmosphere and cloud colours while keeping darker terrain reflections, so the
  far water no longer reflects a grey-white sheet.
* **Distance fog with a LOD floor.** Exponential height fog with the sky's own
  horizon colour as in-scatter, capped so the far LOD is hazed rather than
  erased. The old horizon band (vanilla fog colour mixed over the whole lower
  dome) is gone; the horizon haze is now the atmosphere's own multiple-
  scattering term.
* **Cloud layer options.** `Cumulus amount`, `Altocumulus amount` and
  `Cirrus amount` join coverage and density, so each layer can be removed
  independently.

## What changed in 0.4.5

* **Clouds have a 3D coverage field.** The 2D chart is perturbed at the sample
  by 3D noise with a height-dependent threshold, and an egg-shaped altitude
  profile thins bases and tops.
* **Water breaks its directional lock.** Wind direction varies across the
  surface; the base wavelength is larger and the octaves still rotate by the
  golden angle.
* **Warmer, more vibrant grade.**

## What changed in 0.4.4

* **Photon-style wave field.** Three squared-sine octaves with deep-water
  dispersion, golden-angle rotation and a tiling noise texture in the phase.
* **Clouds in a depth-aware post pass**, so they are visible from above and
  occlude terrain correctly.
* **Photon-style options pages:** General, World, Lighting, Sky, Fog, Materials,
  Water, Post-Processing, Misc and HDR.

## What changed in 0.4.3

* **Waves you can see.** Stronger normals, stronger mirror/refraction
  distortion, a broader sun glint and subtle crest foam.
* **Clouds break vertically.** Per-column base offset and thickness variation,
  with a coarser billow/erosion pair.
* **Lens flare only when the sun is near centre.**

## What changed in 0.4.2

* **LUT sampling fixed and off by default.** Sampling uses texel centres, so a
  white sun stays white and blue water stays blue.
* **Lens flare** with a sun halo, anamorphic streak and four ghosts.
* **A larger sun disc** (about 2.5° across) and a wider sun-space halo.
* **Clouds vary in height** instead of one level slab.
* **Water is noise-led.** Two broad swells plus three scales of chop; the
  directional cross-grid is gone.
* **Less green push, steadier exposure.**

## What changed in 0.4.1

* **Highlights-only bloom.** Bloom is thresholded to HDR highlights, so a bright
  cloud no longer carries its own moving glow; a sun-space halo anchors the
  glare to the sun.

## What changed in 0.4.0

* **Photographic LUT support.** A 33³ identity LUT as a display-referred atlas,
  plus a `.cube` converter.
* **Smaller, separated clouds** with a coverage chart and billow erosion.
* **Distant water stops aliasing.**
* **Readable shadows** and an ambient floor.
* **No vanilla clouds, sun or stars.** The pack draws them.
* **A real shadow map.**
* **LabPBR terrain response** and lit weather.

## What maps 1:1 and what is approximated

| Reference feature | Here |
|---|---|
| Tonemap, grading, vignette, bloom mix | Similar grade, written for Muon (WGSL) (bloom is a 3-ring blur, not the mip chain) |
| HDR (filmic toe, soft shoulder) | Muon (WGSL)'s own shoulder, `HDR output` option |
| Atmosphere / sky | Single-scattering analytic model plus a multiple-scattering horizon term (no sky LUT) |
| Sun/moon shadows | Real 2048² shadow map, 3×3 PCF |
| GTAO | Depth-only GTAO, 4 slices × 5 steps, bilateral denoise |
| SSR | Depth march, water (and optional wet ground) |
| Volumetric light | Screen-space sun shafts |
| Distance fog | Analytic height integral with a capped optical depth, no shadow-map raymarch |
| Water | Five-octave wave field, engine mirror with Muon (WGSL) sky replacement, refraction, absorption, Snell's window from below |
| Clouds | Three depth-aware layers (cumulus, altocumulus, cirrus), cloud-shadow chart on terrain |
| LUT | 33³ display-referred atlas, `.cube` converter included |
| Aurora, SSS, LPV coloured light, DOF, motion blur, TAA, rain puddles | Not in this pack |

The API still gives no G-buffer for entities, no compute and no motion vectors,
so those features remain approximations or are absent.

## Using a LUT

The shader API has no file I/O, so a LUT is baked into the pack as a PNG atlas:
33 blue slices laid out horizontally, width 33×33, height 33. The pack ships an
identity atlas, so nothing changes until you replace it.

1. Convert a 3D `.cube` (Lightroom, Resolve, Affinity, etc.):

   ```sh
   python tools/cube_to_lut_png.py my_look.cube pack/lut.png
   ```

   If red and blue look swapped in game, repeat with `--blue-fastest`.

2. Repack the folder:

   ```sh
   python tools/pack_muon.py pack muon-0.5.1.hshader
   ```

3. In game, enable `Use LUT` and set `LUT strength` to taste. The LUT is
   applied after tonemapping and before dithering, so it behaves like a display
   LUT in a grading app rather than a scene-linear transform. It is off by
   default so an identity atlas cannot alter the picture until you opt in.

## Things to check first in game

1. If water looks too dark or too clear, use `Water absorption` (0 = clear,
   3 = murky).
2. If the sun is too strong, lower `Sunlight intensity`; the default is 7.
3. `Sun/moon shadows` off measures the lighting without the shadow pass.
4. `Distance fog` controls the height fog; 0 removes it.
5. `Cumulus amount`, `Altocumulus amount` and `Cirrus amount` remove layers if
   the GPU cost is too high.
6. `Horizon haze` only affects the last few degrees of the dome; 0 leaves the
   atmosphere untouched.
7. `Output linear` is a debugging switch; leave it off.

Muon (WGSL) is MIT licensed; see `LICENSE`.

## Credits

Muon (WGSL) is an independent WGSL shader. Its look is inspired by the work below; the
WGSL in this pack is Muon (WGSL)'s own implementation.

- **SixthSurge (Benjamin Stott) — Photon.** The reference for Muon (WGSL)'s colour
  grade, atmosphere, water and cloud lighting. Muon (WGSL) keeps the spirit of
  Photon's `c19_color_grading` (Lottes default, log-contrast, hue-band
  saturation, split tone). <https://github.com/SixthSurge/Photon>
- **Photon HDR fork.** The reference for an HDR path that keeps a filmic toe
  and puts a soft shoulder at the display peak. Muon (WGSL) implements that idea in
  `mu_tonemap_hdr`.
- **Public techniques:** Lottes (2016), Hejl–Burgess, Narkowicz ACES fit,
  Uchimura and Reinhard tone curves; Cook–Torrance/GGX/Smith BRDF and Schlick
  Fresnel; Rayleigh/Mie single scattering; deep-water Gerstner dispersion;
  Beer–Lambert and Beer–Powder extinction.
- **Horizon.** Shader API, prelude and stage system:
  <https://github.com/horizon-rust/horizon>

Keep this file and `LICENSE` with any redistribution.
