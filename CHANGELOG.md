# Changelog

## 0.5.1

- Renamed the shader to Muon (WGSL) to keep the plain Muon name free for the
  planned Minecraft shader. The internal pack id (`muon`), `MU_` constants and
  `mu_` functions are unchanged.
- Grade: warmer and more vibrant. Less blue in the terrain ambient, a warmer
  ground bounce, green saturation and a yellow-ward green hue shift, and a
  warmer split-tone.
- Sky: the sky stage now compensates for Horizon's view-bob/nausea pose, so the
  dome no longer rotates against the world while walking.
- Water: distance-scaled reflection blur and a lower default Fresnel cap, so
  reflected land is softer and the surface is less mirror-like.
- Fog: warmer in-scatter, so distant grass does not read cyan.
- Underwater: kept at the 0.5.0 look; the experimental underwater light-shaft
  work was removed.

## 0.5.0

- Clouds: three world-space layers (cumulus/stratocumulus at about 1000 blocks,
  altocumulus/altostratus at about 2800, cirrus/cirrostratus at about 5600), each
  with its own coverage chart, shape field, lighting and aerial perspective.
  The higher, layered deck removes most of the walking parallax that made the
  old 380-block slab read as a ceiling sliding past. New `Cumulus amount`,
  `Altocumulus amount` and `Cirrus amount` options.
- Water: five-octave wave field plus a crossing swell train, filtered by pixel
  footprint rather than distance, so long swells survive to the horizon while
  short ripples cannot alias. The normal fades to a floor at grazing angles
  instead of to zero.
- Water reflection: the engine mirror's vanilla sky pixels are replaced with
  Muon (WGSL)'s atmosphere and cloud colour, so the horizon does not reflect a
  grey-white sheet.
- Fog: exponential height fog using the sky's horizon colour as in-scatter,
  with a capped optical depth so the far LOD stays visible.
- Sky: a multiple-scattering horizon term; the old full-dome vanilla-fog blend
  is reduced to a small last-few-degrees haze so the horizon is blue, not white.
- Repository: every release is kept under `versions/`; `muon-download` is now
  only the built shader, the licence and the LUT converter.

## 0.4.5

- Clouds: 3D coverage perturbation, height-dependent threshold, egg-shaped
  altitude profile; base variation up to ±140 blocks, thickness 50–150%.
- Water: wind direction varies across the lake, larger base wavelength; the
  golden-angle octave stack and noise phase remain.
- Grade: warmer, brighter and more saturated; stronger split tone.

## 0.4.4

- Photon-style wave field: three squared-sine octaves, deep-water dispersion,
  golden-angle rotation and a tiling noise texture in the phase; small normal,
  stronger reflection/refraction distortion and a broader glint.
- Clouds moved to a depth-aware post pass, so they are visible from above and
  occlude terrain correctly. Coverage is smaller, bases vary ±95 blocks and
  thickness 55–145%, with more contrast between lit tops and shaded bases.
- Photon-style Shader Options pages: General, World, Lighting, Sky, Fog,
  Materials, Water, Post-Processing, Misc, HDR.

## 0.4.3

- Stronger water normals, much stronger mirror/refraction distortion, a broader
  sun glint and subtle crest foam so waves read at a glance.
- Cloud columns vary in base (±95 blocks) and thickness (55–145%), with coarser
  billow/erosion to remove the noisy surface.
- Lens flare is faded by sun centring and screen edge, and is weaker by default.

## 0.4.2

- Fixed the LUT atlas sampling: red is now sampled at texel centres instead of
  slice edges, so white no longer turns teal and blue water no longer turns
  pink. `Use LUT` defaults off until a real LUT is installed.
- Added a toggleable lens flare (sun halo, anamorphic streak, four ghosts).
- Enlarged the sun disc to about 2.5° and widened its halo.
- Cloud columns now vary in base/thickness; the deck is no longer a level slab.
- Water is noise-led (two swells + three chop scales); the directional
  cross-grid is gone, and normals fade by pixel footprint at distance.
- Reduced green saturation; auto exposure now uses the eased camera light, not a
  screen average, so it does not pump while walking.

## 0.4.1

- Bloom is thresholded to HDR highlights, so a bright cloud no longer carries
  its own moving glow; added a sun-space halo.

## 0.4.0

- Added display-referred LUT support (identity atlas, `.cube` converter).
- Smaller, separated cumulus; stronger cloud shadowing.
- Pixel-footprint fade for distant water.
- Ambient floor for shaded trunks.

## 0.3.0

- Cloud coverage chart with real gaps, 3D billow erosion and a light march.
- Brighter clear-day sky with dithering.
- Warmer, higher-contrast grade.
- Cloud-shadow chart on terrain.

## 0.2.0

- First public Muon (WGSL) build: real shadow map, water/cloud rework, rewritten grade
  and Muon (WGSL) namespace.

## 0.1.0

- Initial port of the look to Horizon's WGSL API.
