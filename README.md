# Muon (WGSL)

**Muon (WGSL)** is a filmic WGSL shader pack for [Horizon](https://github.com/horizon-rust/horizon),
the Rust rewrite of Minecraft. It rebuilds the sky, clouds, shadows, water and
terrain response in one native pipeline, then finishes with a Photon-inspired
grade, HDR output and a photographic LUT slot.

The look is inspired by [Photon](https://github.com/SixthSurge/Photon) by
SixthSurge. The WGSL in this repository is Muon (WGSL)'s own implementation; the design
notes below explain the choices rather than hiding them behind a preset.

Current release: **0.5.1** · shader API **0.1**

The shader is named **Muon (WGSL)**; the plain Muon name is reserved for
the planned Minecraft shader. The internal pack id stays `muon`, so
existing option files keep working.

## At a glance

| | |
|---|---|
| **Sky** | analytic Rayleigh/Mie atmosphere, a multiple-scattering horizon term, ozone tint, 2.5° sun disc, sun-space halo, stars, moon halo, 8-bit dither |
| **Clouds** | three world-space layers — cumulus/stratocumulus, altocumulus/altostratus and cirrus/cirrostratus — with 2D coverage charts + 3D perturbation, billow erosion, per-column height, multi-scatter light and cloud shadows |
| **Shadows** | 2048² sun/moon map, 128-block range, 3×3 PCF, solid leaf/plant cutouts, translucent colour tinting |
| **Water** | five-octave wave field with deep-water dispersion, two crossing swell trains and footprint filtering; engine mirror with Muon (WGSL) sky/cloud replacement, depth-rejected refraction, Beer–Lambert absorption, Snell's window/TIR, crest foam |
| **Fog** | exponential height fog with the sky's own horizon colour as in-scatter, capped so the far LOD is hazed rather than erased |
| **Terrain** | LabPBR normal/specular, GGX/Smith specular, wrapped diffuse, coloured block light, emission, foliage translucency |
| **Post** | GTAO + denoise, SSR, screen-space sun shafts, HDR-threshold bloom, sun-anchored lens flare, LUT, filmic tonemap, HDR, FXAA, CAS, dither |
| **Weather** | lit rain/snow streaks, suppressed while underwater; the cloud layers grow and flatten into a storm deck |
| **UI** | Photon-style option pages: General · World · Lighting · Sky · Fog · Materials · Water · Post-Processing · Misc · HDR |

---

# Under the hood

## Sky: a physical dome, not a gradient

The sky is a single-scattering atmosphere evaluated per ray:

- Rayleigh and Mie scattering with realistic scale heights
- an ozone term that pulls the zenith blue and warms the horizon at sunset
- separate sun and moon contributions
- a clear-day blue lift so a straight Rayleigh integral does not read grey on a
  display
- sun and moon halos in **direction space**, so they stay glued to the bodies
  while the camera moves

The sun disc is about **2.5°** across with a soft limb, and the whole dome is
dithered before the 8-bit frame store. Smooth sky gradients are exactly where
banding shows, and a full-screen dither costs almost nothing.

A single-scattering integral alone leaves the last few degrees above the horizon
several times too dark and flat, so the atmosphere carries a broad multiple-
scattering horizon term. That term is also the colour the clouds, the water and
the distance fog blend toward: the horizon no longer has to be forced to
vanilla's fog colour, which is what used to turn the whole base of the dome into
a white band.

`MU_HEADROOM = 4.0` in the inter-pass encode is deliberate: sky radiance is
several times brighter than sunlit terrain. Clamping at 1.0 was what made early
versions read as a white dome.

## Clouds: three layers, each with its own weather

Photon's sky is a stack of cloud layers rather than one deck, and Muon (WGSL) now
follows that idea with its own fields:

| Layer | Altitude | Type |
|---|---|---|
| cumulus | ~1000 blocks | cumulus in fair weather, stratocumulus when coverage rises |
| altocumulus | ~2800 blocks | mackerel-sky altocumulus, altostratus in rain |
| cirrus | ~5600 blocks | fibrous cirrus and a thin cirrostratus veil |

Each layer shares the same three ideas:

1. **Coverage chart** — a 2D fBm sampled on the layer's base, domain-warped and
   perturbed at each sample by a 3D noise field with a height-dependent
   threshold. The chart decides whether a column exists; the 3D term decides
   whether it survives at this altitude, so the silhouette is not an extruded
   2D mask.
2. **Billow erosion** — folded 3D billow octaves carve cauliflower tops and torn
   edges. `abs(noise * 2 - 1)` around the midpoint is what gives cumulus their
   shape; plain fBm gives soft blobs.
3. **Per-column height** — each column shifts its base by up to ±85 blocks and
   scales its thickness. An egg-shaped altitude profile thins the base and top.

The layers are not copies of one another. The cumulus layer has the thickest
volume and the strongest billow; altocumulus uses a finer chart, a mackerel cell
field and a much thinner slab; cirrus is a single anisotropic plane sample with
fibrous streaks and a veil. Rain raises coverage, lowers and thickens the
cumulus layer until the same field reads as a stratiform storm deck, grows the
altostratus sheet and suppresses the cirrus.

Lighting is a short march toward the sun through the same density field, with:

- Beer–Lambert transmittance
- a four-term multiple-scatter sum so thick cores do not go black
- Beer–Powder for silver linings
- a height term so shaded bases are cooler than lit tops
- an aerial-perspective blend to the sky's horizon colour

The marching is a **depth-aware post pass**, not a sky-stage effect. It rays from
the world camera, stops at scene depth, and composites in front of terrain. That
is what lets you fly **above** the deck and still see it. A cloud-shadow chart is
projected onto the terrain from the same coverage maps.

The layers sit high and are anchored in world space. That is deliberate: a deck
at 380 blocks reads as a ceiling sliding past when you walk, while the same
clouds at 1000 blocks and above move by a small enough parallax to read as sky.
The old low single slab was the reason the deck seemed to travel with the player
on foot.

## Shadows: a real map, not a sky-light proxy

`[shadow]` builds a 2048² depth map from the sun by day and the moon by night.

- 128-block shadow distance
- 3×3 PCF with a texel-scaled radius
- leaves and plants are treated as solid so canopies cast whole shadows instead
  of punching cutout holes
- `shadow_map_translucent` and `shadow_color` tint sunlight that passes through
  water or stained glass
- a normal-offset bias plus a slope-aware comparison bias keep acne off

The terrain shader evaluates direct sun/moon, wrapped diffuse, a sky/ground
ambient floor, coloured block light and emission. Foliage gets a larger wrap and
a backlit translucency term; plants are lit with an upward-biased normal because
flat quads otherwise go black on one side.

## Water: a filtered wave spectrum, not one repeating ripple

The wave field follows the logic Photon uses but resolves it for a surface that
reaches the horizon:

- **five octaves** of a squared-sine Gerstner profile, plus a second, crossing
  three-octave swell train
- **deep-water dispersion**, `ω = √(gk)`, so long waves outrun short ones
- **golden-angle rotation** each octave so the wave trains do not line up
- a **tiling noise texture** read once per pixel as a common crest wander, with
  analytic noise for the per-octave variation
- a low-frequency gust/patch field that makes some areas choppier

The important difference is that the octaves are filtered by **pixel
footprint**, not by distance alone. As a wave train's wavelength falls under a
few pixels it fades out; the long swells remain. That keeps high-frequency
ripples from aliasing into a flat sheet and keeps a visible low-frequency normal
at the horizon, where the old distance fade had removed everything.

The normal is computed from the analytic slope, not from finite differences of
the height. It is deliberately **small** — Photon-style, around 0.02–0.06 plus
rain — because the visibility comes from the reflection and specular pipeline,
not from huge normals. At grazing incidence the normal fades to a floor, not to
zero, so the far lake is not a perfect mirror.

Muon (WGSL) then adds:

- the engine's half-resolution **water mirror**, distorted by the wave normal
- a **replacement for the mirror's sky**: the engine mirror contains vanilla's
  sky gradient, so its sky pixels are swapped for Muon (WGSL)'s atmosphere and cloud
  colours while darker terrain reflections are kept. This is what stops the
  horizon reflecting a grey-white sheet
- **screen-space refraction** with depth rejection, so seabed steps do not smear
- **Beer–Lambert absorption** by the thickness of water behind the surface
- a **GGX sun glint** with a broad lobe
- **crest foam** on the highest wave samples, close to the camera
- **Snell's window and total internal reflection** from below, so the underside
  is a real water-air interface instead of the vanilla animated texture

## Fog: aerial perspective that leaves the LOD readable

The distance fog is an exponential height integral, not a screen-space grey
wash:

- density falls with altitude, so a high camera sees clear air and a valley
  fills with haze
- the in-scatter uses the sky's own horizon colour plus a forward Mie lobe
  around the sun, so haze warms toward the light instead of greying out
- rain and thunder thicken it
- the optical depth is capped, so the far LOD is hazed rather than erased

The cap is the LOD part. The fog is strongest around the middle distance and
then levels off, leaving the last ring of distant terrain and the LOD tiles
visible through it. There is no separate fog colour to tune against the LOD:
both use the same sky horizon term the clouds and water use.

## Terrain: LabPBR and a readable ambient

The material stage reads the current API's surface data directly:

- LabPBR normal and specular maps (smoothness, F0/metal, porosity, emission)
- tangent-space normal mapping
- GGX/Smith specular with Schlick Fresnel
- wrapped diffuse for a softer terminator
- coloured block light from the engine's light volume
- emission from both the block kind and the LabPBR map
- a small sky/ground ambient floor plus a warm bounce, so trunks and shaded
  sides keep detail at distance

## Post: effects with a reason

| Pass | What it does | Why |
|---|---|---|
| GTAO | depth-only horizon occlusion | contact shading without a G-buffer |
| AO denoise | bilateral blur | removes the GTAO noise pattern |
| SSR | depth march with thickness rejection | reflections on water and smooth ground |
| Volumetrics | screen-space sun shafts + capped height fog | crepuscular light and aerial perspective that leaves the LOD readable |
| Clouds | depth-aware raymarch of three layers | cumulus, altocumulus and cirrus above and below the camera |
| Grade | bloom + exposure + filmic grade + tonemap | the look |
| FXAA | spatial edge filter | the pack replaces Horizon's AA resolve |
| Final | CAS, LUT, dither, output encode | sharpness, look, clean 8-bit output |

**Bloom** is thresholded at HDR luminance 1.0 by default. A bright cloud drifting
past used to carry its own glow; now only the sun disc and genuinely emissive
surfaces bloom. **Lens flare** is gated by sun centring and screen edge, with a
sun-space halo, an anamorphic streak and four lens ghosts.

**LUTs** are display-referred and applied after tone mapping. Because the API has
no file I/O, a 3D LUT is baked into a 33³ PNG atlas; `tools/cube_to_lut_png.py`
converts Resolve/Lightroom/Affinity `.cube` files.

## HDR and the grade

The SDR path is a Lottes curve by default, with Hejl–Burgess, Uncharted 2, Tech
and Reinhard Jodie available. The grade is a filmic chain:

- log-contrast around 18% grey
- hue-band saturation (orange/teal/green)
- a cool-shadow / warm-highlight split tone
- a small S-curve
- Rec.2020 working space, converted back to Rec.709 for output

The HDR path keeps the filmic toe and hands the highlights to a soft exponential
shoulder at the display peak, relative to paper white. Peak and paper-white nits
are options, not hard-coded.

## Design notes

- **Clouds after volumetrics.** Clouds should not be darkened by GTAO or
  reflected by SSR using the terrain's depth. They composite after those passes
  and before grading.
- **High, world-anchored layers.** A cloud deck at 380 blocks slides across the
  sky as you walk. At 1000 blocks and above the parallax is small enough to read
  as sky, while the layers are still low enough to fly above. The layers are
  sampled from the world camera, not from a camera-locked dome.
- **Coverage in 2D, shape in 3D.** The chart decides whether a column exists;
  billow erosion and the height-dependent 3D threshold decide what survives.
  One without the other gives either an extruded mask or a shapeless fog.
- **Small water normals, filtered by footprint.** Large normals look like
  rubber. Small normals plus strong reflection/refraction distortion look like
  water — but only if the high-frequency octaves fade before they alias.
- **The mirror holds vanilla's sky.** Horizon's water reflection includes the
  engine sky gradient, not the pack's sky. Water must replace those pixels with
  its own atmosphere/cloud colour, or the horizon becomes a white sheet.
- **Fog with a floor.** A physically increasing fog would erase the LOD. Capping
  the optical depth and reusing the sky horizon colour keeps the far ring
  visible as haze rather than as a blank wall.
- **Dither before storage.** A smooth sky gradient in 8 bits will band; dithering
  the sky and the final image is cheaper than a 16-bit frame.
- **No sky-light shadow proxy.** The shadow map is the real thing; terrain
  direct light is not gated by a smoothstep on sky light.

## Performance

The pack targets a modern discrete GPU. The manifest declares a `gpu_ms` budget
of 14 ms; the biggest costs are the three cloud layers, GTAO/SSR and the shadow
map. On a 1440p frame the cloud pass is the first thing to reach for. Useful
knobs:

- `Sun/moon shadows` off removes the shadow pass
- `Cumulus amount`, `Altocumulus amount` and `Cirrus amount` remove whole layers
- `Cloud coverage`/`Cloud density` reduce cloud work
- `Distance fog` 0 removes the height-fog integral
- `GTAO strength` 0 skips the AO contribution
- `Screen-space reflections` Off removes the SSR march
- `Volumetric light intensity` 0 removes the shaft march
- `HDR output` off uses the SDR path

## Not in this pack

The API still has no entity G-buffer, no compute, no persistent history and no
motion vectors, so these are absent or approximated:

- entity/particle shading beyond Horizon's own
- FFT ocean spectrum and displacement
- volumetric cloud shadow maps
- TAA, motion blur, depth of field
- rain puddles/wetness simulation
- aurora and LPV coloured light

They are good candidates for later stages, not things the current pass chain
pretends to do.

---

## Requirements

- A Horizon build that serves shader API 0.1 with the shadow, reflection and
  weather stages (the current nightly does).
- No dependencies for the shader itself. The Python tools need Python 3 and
  Pillow.

## Install

1. Copy `dist/muon-0.5.1.hshader` (or the `pack/` folder) into your Horizon
   `shaderpacks/` directory:
   - Windows: `%APPDATA%\horizon\shaderpacks\`
   - The folder or the `.hshader` both work.
2. In game: **Options → Video Settings → Shader Packs**, select **Muon (WGSL)**.
3. A folder install lets Horizon hot-reload edits and a replaced `lut.png`
   within about half a second.

The `muon-download` release bundle is deliberately small: the built `.hshader`,
`LICENSE`, and `cube_to_lut_png.py`. Everything else lives here in the source
repository.

## LUTs

```sh
python tools/cube_to_lut_png.py my_look.cube pack/lut.png
python tools/pack_muon.py pack muon-0.5.1.hshader
```

The release bundle's converter can also replace the atlas inside the built
shader in one step:

```sh
python cube_to_lut_png.py my_look.cube lut.png --pack muon-0.5.1.hshader
```

Enable **Use LUT** and set **LUT strength**. Full details, including the `.cube`
data order and Lightroom/Resolve export notes, are in [docs/LUT.md](docs/LUT.md).

## Build

```sh
cd pack
python ../tools/make_identity_lut.py
cd ..
python tools/pack_muon.py pack muon-0.5.1.hshader
```

## Repository layout

```
pack/                 shader source, lut.png, water_noise.png
tools/                LUT converter, identity LUT, noise generator, packer
docs/                 LUT guide
dist/                 built .hshader
versions/             every released .hshader, kept for history
```

## Version history

Every release is kept as a built `.hshader` under `versions/` and at the
workspace root, so any earlier look can be restored without rebuilding it. The
files are the full packs: source, manifest, LUT and noise are all inside.

## Credits

- **SixthSurge (Benjamin Stott) — Photon**: reference for the look, grade
  structure, atmosphere, water and cloud lighting.
  <https://github.com/SixthSurge/Photon>
- **Photon HDR fork**: reference for the HDR toe/shoulder approach.
- **Public techniques**: Lottes (2016), Hejl–Burgess, Narkowicz ACES fit,
  Uchimura and Reinhard tone curves; Cook–Torrance/GGX/Smith and Schlick
  Fresnel; Rayleigh/Mie scattering; Gerstner dispersion; Beer–Lambert and
  Beer–Powder extinction.
- **Horizon** for the shader API, prelude and stage system.

Muon (WGSL) is an independent implementation and does not include Photon's GLSL
source. Not affiliated with Mojang, Microsoft or the Horizon project.

## License

MIT — see [LICENSE](LICENSE).
