// Photon-style lighting for terrain, distant LOD tiles and translucent blocks.
//
// This stage uses the current shader API's real surface data: `input.normal`
// (instead of a constructed derivative normal), the sun/moon shadow map, LabPBR
// normal/specular maps, the coloured block-light volume, the engine water
// mirror and the pre-translucent colour/depth for water refraction. That is what
// keeps foliage and stone from reading flat: the old sky-light proxy lit every
// surface the same and gave nothing a cast shadow.

const MAT_LEAVES: u32 = 10u;
const MAT_PLANTS: u32 = 11u;

fn mu_h21(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    q = q + vec3<f32>(dot(q, q.yzx + vec3<f32>(33.33)));
    return fract((q.x + q.y) * q.z);
}

fn mu_vnoise2(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (vec2<f32>(3.0) - 2.0 * f);
    let a = mu_h21(i);
    let b = mu_h21(i + vec2<f32>(1.0, 0.0));
    let c = mu_h21(i + vec2<f32>(0.0, 1.0));
    let d = mu_h21(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// ---------------------------------------------------------------------
//   Shadows
// ---------------------------------------------------------------------

// 3x3 PCF through the comparison sampler. `shadow_softness` widens the kernel;
// the bias scales with the ground a texel covers so it holds at 128 or 256 m.
fn mu_shadow_visibility(position: vec3<f32>, normal: vec3<f32>) -> f32 {
    if (!shadows_enabled || frame.has_shadow == 0u) { return 1.0; }
    let bias = frame.shadow_center_texel * 0.9 + 0.002;
    let p = shadow_position(position + normal * bias);
    if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0 || p.z > 1.0) {
        return 1.0;
    }
    let texel = 1.0 / max(frame.shadow_resolution, 1.0);
    let radius = texel * (0.9 + shadow_softness * 1.6);
    var sum = 0.0;
    for (var y = -1; y <= 1; y = y + 1) {
        for (var x = -1; x <= 1; x = x + 1) {
            let offset = vec2<f32>(f32(x), f32(y)) * radius;
            sum = sum + textureSampleCompareLevel(shadow_map, shadow_sampler, p.xy + offset, p.z - 0.0008);
        }
    }
    return sum / 9.0;
}

// Sunlight that passed through stained glass or water: lit in the solid map but
// not in the translucent one means a coloured sheet is between it and the sun.
fn mu_shadow_translucent_tint(position: vec3<f32>, normal: vec3<f32>) -> vec3<f32> {
    if (!shadows_enabled || frame.has_shadow == 0u) { return vec3<f32>(1.0); }
    let base = shadow_position(position + normal * frame.shadow_center_texel * 0.9);
    if (base.x < 0.0 || base.x > 1.0 || base.y < 0.0 || base.y > 1.0 || base.z > 1.0) {
        return vec3<f32>(1.0);
    }
    let solid = textureSampleCompareLevel(shadow_map, shadow_sampler, base.xy, base.z);
    let through = textureSampleCompareLevel(shadow_map_translucent, shadow_sampler, base.xy, base.z);
    if (solid > 0.5 || through < 0.5) { return vec3<f32>(1.0); }
    let dims = vec2<f32>(textureDimensions(shadow_color));
    let texel = vec2<i32>(base.xy * dims);
    return textureLoad(shadow_color, texel, 0).rgb;
}

// ---------------------------------------------------------------------
//   BRDF
// ---------------------------------------------------------------------

fn mu_d_ggx(NoH: f32, a: f32) -> f32 {
    let a2 = a * a;
    let d = NoH * NoH * (a2 - 1.0) + 1.0;
    return a2 / max(MU_PI * d * d, 1e-6);
}

fn mu_g_smith(NoV: f32, NoL: f32, a: f32) -> f32 {
    let k = a * 0.5;
    let gv = NoV / max(NoV * (1.0 - k) + k, 1e-5);
    let gl = NoL / max(NoL * (1.0 - k) + k, 1e-5);
    return gv * gl;
}

fn mu_specular(n: vec3<f32>, v: vec3<f32>, l: vec3<f32>, roughness: f32, f0: vec3<f32>) -> vec3<f32> {
    let h = normalize(v + l);
    let NoV = mu_sat(dot(n, v));
    let NoL = mu_sat(dot(n, l));
    let NoH = mu_sat(dot(n, h));
    let a = max(roughness * roughness, 0.002);
    return f0 * (mu_d_ggx(NoH, a) * mu_g_smith(NoV, NoL, a) / max(4.0 * NoV * NoL, 1e-5));
}

// Fresnel for water -> air, including total internal reflection. Looking up
// through the surface from below is what makes Snell's window.
fn mu_fresnel_water_air(cos_i_in: f32) -> f32 {
    let eta = 1.333;
    let cos_i = mu_sat(cos_i_in);
    let sin_t2 = eta * eta * max(1.0 - cos_i * cos_i, 0.0);
    if (sin_t2 >= 1.0) { return 1.0; }
    let cos_t = sqrt(1.0 - sin_t2);
    let rs = (eta * cos_i - cos_t) / max(eta * cos_i + cos_t, 1e-5);
    let rp = (eta * cos_t - cos_i) / max(eta * cos_t + cos_i, 1e-5);
    return 0.5 * (rs * rs + rp * rp);
}

// ---------------------------------------------------------------------
//   Water
// ---------------------------------------------------------------------

// A five-octave wave field with deep-water dispersion. The octaves fade by
// pixel footprint instead of by distance alone: high-frequency ripples go
// away before they alias, while the long swells remain all the way to the
// horizon. That is what keeps a distant lake from turning into a mirror.
// Returns (height, slope.x, slope.z).
struct MuWaterField {
    height: f32,
    slope: vec2<f32>,
};

fn mu_water_field(p: vec2<f32>, footprint: f32) -> MuWaterField {
    let t = frame.time * water_speed;
    let gust_patch = mu_vnoise2(p * 0.0032 + vec2<f32>(2.7, 9.1));
    let gust = 0.55 + 0.70 * mu_vnoise2(p * 0.0017 + vec2<f32>(11.0, 3.0));
    let wind_angle = 0.62 + (gust_patch - 0.5) * 1.55;
    var dir = vec2<f32>(cos(wind_angle), sin(wind_angle));

    // One tiling texture read gives every crest a common wander; the rest of
    // the field is analytic, so it is cheap and filterable at distance.
    let ntex = textureSampleLevel(water_noise, water_noise_sampler,
        (p + vec2<f32>(0.0, 0.18 * t)) * 0.0045, 0.0).r * 2.0;

    let cr = cos(2.3999632);
    let sr = sin(2.3999632);
    var height = 0.0;
    var slope = vec2<f32>(0.0);
    var wavelength = 42.0;
    var amp = 0.045;
    for (var i = 0; i < 5; i = i + 1) {
        let k = 6.2831853 / wavelength;
        let w = sqrt(9.8 * k);
        let noise = ntex * 0.80 + mu_vnoise2(p * 0.020 + vec2<f32>(f32(i) * 3.7)) * 0.55;
        let x = w * t - k * (dot(dir, p) + noise * 5.0);
        let s = sin(x) * 0.5 + 0.5;
        let c = cos(x);
        let lod = smoothstep(footprint * 2.2, footprint * 7.0, wavelength);
        height = height + s * s * amp * lod;
        slope = slope + dir * (s * c * k * amp * lod) * 3.0;
        dir = vec2<f32>(cr * dir.x - sr * dir.y, sr * dir.x + cr * dir.y);
        wavelength = wavelength * 1.62;
        amp = amp * 0.66;
    }

    // A cross-running chop breaks the parallel trains and gives the far
    // water a second, slower direction to read against.
    var dir2 = vec2<f32>(0.42, -0.91);
    var wl2 = 26.0;
    var amp2 = 0.030;
    for (var i = 0; i < 3; i = i + 1) {
        let k = 6.2831853 / wl2;
        let w = sqrt(9.8 * k);
        let x = w * t * 1.07 - k * dot(dir2, p + vec2<f32>(3.0, 1.0));
        let s = sin(x) * 0.5 + 0.5;
        let c = cos(x);
        let lod = smoothstep(footprint * 2.2, footprint * 7.0, wl2);
        height = height + s * s * amp2 * lod * 0.65;
        slope = slope + dir2 * (s * c * k * amp2 * lod) * 3.0;
        wl2 = wl2 * 1.70;
        amp2 = amp2 * 0.60;
        dir2 = vec2<f32>(0.91, 0.42);
    }

    // Some patches are choppier than others, so the surface is not uniform
    // even where the wave trains are parallel.
    let variation = max(0.45, mu_vnoise2(p * 0.0012 + vec2<f32>(0.0, 0.05 * t)) * 1.8 - 0.3);
    return MuWaterField(height * variation, slope * variation * gust);
}

// Water normal in world axes. For the top face it points up, for the underside
// it is flipped so it faces the camera below the surface.
fn mu_water_normal(input: MaterialInput, flat_normal: vec3<f32>) -> vec3<f32> {
    let flat = normalize(flat_normal);
    if (abs(flat.y) < 0.5) {
        return flat;
    }
    let p = -(input.position.xz + frame.camera_position.xz);
    let dist = length(input.position);
    let view = normalize(-input.position);
    let footprint = max(0.05, dist * 0.0018);
    let field = mu_water_field(p, footprint);
    // Grazing water needs a *non-zero* ripple: at the horizon the normal is
    // what gives the mirror its texture, so this fades toward a floor rather
    // than toward zero.
    let grazing = mix(0.42, 1.0, smoothstep(0.0, 0.12, abs(dot(flat, view))));
    let sky_damp = mix(0.55, 1.0, mu_sat(input.light.y));
    let rain = 1.0 + 0.85 * frame.rain;
    let influence = 0.50 * water_waves * grazing * sky_damp * rain;
    var n = normalize(vec3<f32>(field.slope.x * influence, 1.0, field.slope.y * influence));
    if (flat.y < 0.0) { n = -n; }
    return n;
}

fn mu_opaque_distance(screen: vec2<i32>, depth: f32) -> f32 {
    if (depth <= 0.0) { return 1.0e4; }
    let uv = (vec2<f32>(screen) + vec2<f32>(0.5)) / frame.resolution;
    let clip = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    let v = frame.projection_inverse * clip;
    return length(v.xyz / max(abs(v.w), 1e-6));
}

fn mu_water_hue(input: MaterialInput) -> vec3<f32> {
    let t = max(input.tint.rgb, vec3<f32>(0.001));
    return t / max(max(t.r, max(t.g, t.b)), 0.001);
}

// The engine's mirror holds vanilla's sky, not Muon (WGSL)'s: it is a real render of
// the world, but the sky in it is the engine's gradient. This adds Muon (WGSL)'s own
// cloud deck to the analytic sky so a reflected horizon is not just a white
// sheet. It is deliberately cheap: coverage, not a full march.
fn mu_water_clouds(dir: vec3<f32>, origin: vec3<f32>) -> vec3<f32> {
    if (dir.y <= 0.002) { return vec3<f32>(0.0); }
    let wet = mu_wetness();
    let coverage = clamp(cloud_coverage + 0.30 * wet, 0.0, 1.0);
    let thr = mix(0.67, 0.41, coverage);
    let sun = frame.sun_direction;
    let day = smoothstep(-0.08, 0.12, sun.y);
    let light_col = mix(vec3<f32>(0.012, 0.018, 0.030),
                        mu_sun_color(sun.y) * 1.35, day)
        + mu_srgb_decode(frame.sky_color) * (0.18 + 0.20 * day);
    var c = vec3<f32>(0.0);

    let t0 = (MU_CUMULUS_BASE - origin.y) / dir.y;
    if (t0 > 0.0 && cloud_cumulus > 0.001) {
        let p = origin + dir * t0;
        let m = smoothstep(thr, thr + 0.16, mu_cumulus_chart(p.xz, frame.time));
        c = c + light_col * (m * cloud_cumulus * 0.85);
    }

    let t1 = (MU_ALTO_BASE - origin.y) / dir.y;
    if (t1 > 0.0 && cloud_altocumulus > 0.001) {
        let p = origin + dir * t1;
        let m = smoothstep(thr + 0.04, thr + 0.18,
                           mu_altocumulus_chart(p.xz, frame.time));
        c = c + light_col * (m * cloud_altocumulus * 0.45);
    }

    let t2 = (MU_CIRRUS_ALT - origin.y) / dir.y;
    if (t2 > 0.0 && cloud_cirrus > 0.001) {
        let p = origin + dir * t2;
        let m = mu_cirrus_density(p.xz, frame.time);
        c = c + light_col * (m * 0.40);
    }
    // A grazing reflection crosses an enormous sample footprint. Fade the
    // cloud part out there so the horizon does not turn into white speckle.
    return c * smoothstep(0.008, 0.060, dir.y);
}

fn mu_water_top(input: MaterialInput, flat: vec3<f32>) -> vec4<f32> {
    let view = normalize(-input.position);
    let dist = length(input.position);
    let n = mu_water_normal(input, flat);
    let ndv = mu_sat(dot(n, view));
    let fresnel = clamp((0.02 + 0.98 * pow(1.0 - ndv, 5.0)) * water_fresnel, 0.0, 1.0);
    let day = smoothstep(-0.08, 0.12, frame.sun_direction.y);
    let sun_col = mu_sun_color(frame.sun_direction.y) * (sun_intensity * 0.17);
    let shadow = mix(1.0, mu_shadow_visibility(input.position, n), shadow_strength)
        * mu_cloud_shadow(input.position + frame.camera_position);

    // Refraction: bend only by the wave's deviation from the flat surface, and
    // fall back to the straight sample where the bend would fetch something in
    // front of the water (otherwise seabed steps become black blotches).
    let screen = clamp(vec2<i32>(input.screen * frame.resolution),
                       vec2<i32>(0), vec2<i32>(frame.resolution) - vec2<i32>(1));
    let wave = n.xz - flat.xz;
    let offset = vec2<i32>(wave * (60.0 * water_refraction / (1.0 + dist * 0.05)));
    let limit = vec2<i32>(frame.resolution) - vec2<i32>(1);
    let screen_r = clamp(screen + offset, vec2<i32>(0), limit);
    let straight_e = textureLoad(opaque_color, screen, 0).rgb;
    let bent_e = textureLoad(opaque_color, screen_r, 0).rgb;
    let straight_depth = textureLoad(opaque_depth, screen, 0);
    let bent_depth = textureLoad(opaque_depth, screen_r, 0);
    let valid = select(0.0, 1.0, bent_depth <= straight_depth);
    let behind_e = mix(straight_e, bent_e, valid);
    let behind = mu_scene_decode(behind_e);

    var thickness = 0.0;
    if (frame.eye_in != 1u) {
        let behind_depth = mix(straight_depth, bent_depth, valid);
        thickness = clamp(mu_opaque_distance(screen, behind_depth) - dist, 0.0, 64.0);
    }
    let absorb = vec3<f32>(0.39, 0.14, 0.07) * water_fog;
    let transmit = exp(-absorb * thickness);
    let hue = mu_water_hue(input);
    let scatter = hue * vec3<f32>(0.035, 0.150, 0.200) * (0.2 + 0.8 * day) * (vec3<f32>(1.0) - transmit);
    let through = behind * transmit + scatter;

    // The reflection ray and Muon (WGSL)'s own sky (with the cloud deck added).
    let r = reflect(-view, n);
    var sky_refl = mu_sky_radiance(r, 5) * sky_intensity;
    sky_refl = sky_refl * mix(vec3<f32>(0.78, 0.91, 1.16), vec3<f32>(1.0),
                              smoothstep(0.0, 0.28, r.y));
    sky_refl = sky_refl + mu_water_clouds(r, frame.camera_position);

    // Engine water mirror (half resolution). The mirror is a perfect render,
    // which makes a reflected shore look like a second copy of the world. A
    // 3x3 filter whose radius grows with distance gives the surface a little
    // roughness without destroying the reflection.
    var reflected = sky_refl;
    if (reflections && frame.has_reflection == 1u) {
        let ruv = clamp(input.screen + wave * 0.45, vec2<f32>(0.002), vec2<f32>(0.998));
        let blur = (1.0 + 4.0 * smoothstep(8.0, 140.0, dist) + 5.0 * frame.rain)
            * water_reflection_blur;
        let px = vec2<f32>(blur) / frame.resolution;
        let c0 = textureSampleLevel(reflection, reflection_sampler, ruv, 0.0).rgb;
        let c1 = textureSampleLevel(reflection, reflection_sampler, ruv + vec2<f32>(px.x, 0.0), 0.0).rgb;
        let c2 = textureSampleLevel(reflection, reflection_sampler, ruv - vec2<f32>(px.x, 0.0), 0.0).rgb;
        let c3 = textureSampleLevel(reflection, reflection_sampler, ruv + vec2<f32>(0.0, px.y), 0.0).rgb;
        let c4 = textureSampleLevel(reflection, reflection_sampler, ruv - vec2<f32>(0.0, px.y), 0.0).rgb;
        let c5 = textureSampleLevel(reflection, reflection_sampler, ruv + px, 0.0).rgb;
        let c6 = textureSampleLevel(reflection, reflection_sampler, ruv - px, 0.0).rgb;
        let c7 = textureSampleLevel(reflection, reflection_sampler, ruv + vec2<f32>(px.x, -px.y), 0.0).rgb;
        let c8 = textureSampleLevel(reflection, reflection_sampler, ruv + vec2<f32>(-px.x, px.y), 0.0).rgb;
        let mirror = mu_scene_decode(
            (c0 * 4.0 + (c1 + c2 + c3 + c4) * 2.0 + (c5 + c6 + c7 + c8)) / 16.0
        );

        // The mirror's sky is vanilla's gradient, so swap those pixels for
        // Muon (WGSL)'s sky. A reflected tree line is darker and more saturated than
        // the gradient and survives the comparison; a fogged far shore is
        // close enough to the horizon colour that replacing it is harmless.
        let vanilla_sky = mu_scene_decode(mix(frame.fog_color, frame.sky_color,
            smoothstep(0.02, 0.45, r.y)));
        let delta = length(mirror - vanilla_sky)
            / max(length(vanilla_sky) + length(mirror), 1.0e-3);
        let sky_like = 1.0 - smoothstep(0.10, 0.42, delta);
        let high = smoothstep(0.10, 0.55, r.y);
        let sky_mask = clamp(max(sky_like, high * 0.90), 0.0, 1.0);
        reflected = mix(mirror * 0.94 + sky_refl * 0.06, sky_refl, sky_mask);
    }

    // Grazing reflections read as a white sheet when the sky is pale. Keep a
    // little of the water's own blue in them instead of letting the horizon
    // colour take over completely.
    let grazing = 1.0 - smoothstep(0.0, 0.26, abs(dot(view, flat)));
    reflected = mix(reflected, reflected * vec3<f32>(0.78, 0.94, 1.14), grazing * 0.55);

    let glint = mu_specular(n, view, frame.light_direction, 0.085, vec3<f32>(0.02))
        * sun_col * 10.0 * shadow;
    var color = mix(through, reflected, fresnel) + glint;

    // A little crest foam, so the waves have a readable shape at a glance.
    // It is kept near the camera: at distance the filtered field would turn
    // every crest into a white speck.
    let wp = input.position.xz + frame.camera_position.xz;
    let crest = mu_water_field(wp, 0.28);
    let near = 1.0 - smoothstep(24.0, 110.0, dist);
    let foam = smoothstep(0.255, 0.345, crest.height) * 0.030 * water_waves
        * (0.35 + 0.65 * frame.rain) * near;
    color = mix(color, vec3<f32>(0.78, 0.88, 0.94), foam);
    return vec4<f32>(mu_scene_encode(max(color, vec3<f32>(0.0))), 1.0);
}

// The underside is a water-air interface: mostly a mirror (total internal
// reflection) with Snell's window near the zenith. It never samples the block
// texture, which is what removes the vanilla animated water sheet from below.
fn mu_water_under(input: MaterialInput, flat: vec3<f32>) -> vec4<f32> {
    let view = normalize(-input.position);
    let day = smoothstep(-0.08, 0.12, frame.sun_direction.y);
    let n = mu_water_normal(input, flat);
    let ndv = mu_sat(dot(n, view));
    var fresnel = mu_fresnel_water_air(ndv);

    let hue = mu_water_hue(input);
    let deep = hue * vec3<f32>(0.020, 0.090, 0.120) * (0.20 + 0.80 * day);

    // Refract the view ray from water into air. TIR makes `refract` return 0;
    // in that case the window is not visible and only the deep term remains.
    let inc = -view;
    let rdir = refract(inc, n, 1.333);
    var window = vec3<f32>(0.0);
    if (dot(rdir, rdir) > 1.0e-6) {
        // The sky seen through Snell's window is the atmospheric dome, not the
        // post-processed sky; scale it so the window reads as a bright opening
        // rather than a dark hole.
        window = mu_sky_radiance(normalize(rdir), 8) * 3.2
            + mu_srgb_decode(frame.sky_color) * 0.06;
        // Sun glint through the window.
        let sun = frame.sun_direction;
        let h = normalize(rdir + sun);
        let glint = pow(mu_sat(dot(h, sun)), 900.0) * 2.0;
        window = window + mu_sun_color(sun.y) * glint * smoothstep(0.0, 0.15, sun.y);
    }
    if (dot(rdir, rdir) <= 1.0e-6) { fresnel = 1.0; }

    let color = mix(window, deep, fresnel);
    // A little wave shimmer on the mirror, so it is not a flat sheet.
    let shimmer = 0.98 + 0.02 * sin(frame.time * 1.7 + input.position.x * 0.9 + input.position.z * 0.7);
    return vec4<f32>(mu_scene_encode(max(color * shimmer, vec3<f32>(0.0))), 1.0);
}

fn mu_water_side(input: MaterialInput, flat: vec3<f32>) -> vec4<f32> {
    let view = normalize(-input.position);
    let n = normalize(flat);
    let ndv = mu_sat(dot(n, view));
    let fresnel = clamp((0.02 + 0.98 * pow(1.0 - ndv, 5.0)) * water_fresnel, 0.0, 1.0);
    let day = smoothstep(-0.08, 0.12, frame.sun_direction.y);
    let hue = mu_water_hue(input);
    let deep = hue * vec3<f32>(0.015, 0.075, 0.095) * (0.2 + 0.8 * day);
    let reflected = mu_sky_radiance(reflect(-view, n), 6);
    let color = mix(deep, reflected, fresnel);
    return vec4<f32>(mu_scene_encode(max(color, vec3<f32>(0.0))), 1.0);
}

// ---------------------------------------------------------------------
//   Material
// ---------------------------------------------------------------------

fn material(input: MaterialInput) -> Surface {
    let view = normalize(-input.position);
    let geometric = normalize(input.normal);
    let dist = length(input.position);

    // Fluid is the reliable test for water (and catches the underside, where the
    // old normal.y > 0.9 test failed and the vanilla texture came through).
    // LOD water has no fluid flag, so fall back to a translucent, blue, flat
    // surface for those tiles.
    var is_water = input.fluid == 1u || input.material == 12u;
    if (!is_water && input.translucent && abs(geometric.y) > 0.9 && input.tint.b > input.tint.r * 1.05) {
        is_water = true;
    }

    if (is_water) {
        if (geometric.y < -0.5) {
            return Surface(mu_water_under(input, geometric));
        }
        if (geometric.y > 0.5) {
            return Surface(mu_water_top(input, geometric));
        }
        return Surface(mu_water_side(input, geometric));
    }

    // LabPBR: without maps these return "no detail, dielectric, no emission".
    let normal_map = block_normal_map(input.uv);
    let specular_map = block_specular_map(input.uv);
    let tangent = input.tangent.xyz;
    let bitangent = cross(geometric, tangent) * input.tangent.w;
    let tbn = mat3x3<f32>(tangent, bitangent, geometric);
    let tn = vec2<f32>(normal_map.x * 2.0 - 1.0, normal_map.y * 2.0 - 1.0);
    var n = normalize(tbn * vec3<f32>(tn.x, tn.y, sqrt(mu_sat(1.0 - dot(tn, tn)))));

    // Undo vanilla's directional face shade for axis-aligned faces only, so the
    // pack's own N.L is not multiplied by the game's. Vertex AO and biome tint
    // stay in the tint.
    let an = abs(geometric);
    let aligned = max(an.x, max(an.y, an.z)) > 0.97;
    let vshade = select(0.5, 1.0, geometric.y >= 0.0) * an.y + 0.6 * an.x + 0.8 * an.z;
    let tint = input.tint.rgb / select(1.0, max(vshade, 0.4), aligned);

    let albedo = mu_srgb_decode(input.albedo.rgb) * tint;
    let is_foliage = input.material == MAT_LEAVES || input.material == MAT_PLANTS;

    // Plants are flat quads. Lighting them by the quad normal makes one side of
    // every plant black and the other flat; bias toward up, as the reference does.
    var n_light = n;
    if (is_foliage) {
        n_light = normalize(mix(n, vec3<f32>(0.0, 1.0, 0.0), 0.65));
    }

    let sun = frame.sun_direction;
    let moon = frame.moon_direction;
    let day = smoothstep(-0.08, 0.12, sun.y);
    let weather = 1.0 - 0.55 * frame.rain - 0.10 * frame.thunder;
    let light_dir = frame.light_direction;
    let sun_col = mu_sun_color(sun.y) * (sun_intensity * 0.17) * weather;
    let moon_col = vec3<f32>(0.55, 0.68, 0.95) * 0.14 * smoothstep(-0.08, 0.12, moon.y);
    let light_col = select(moon_col, sun_col, day > 0.0);
    let shadow = mix(1.0, mu_shadow_visibility(input.position + n * 0.02, n), shadow_strength)
        * mu_cloud_shadow(input.position + frame.camera_position);
    let through_tint = mu_shadow_translucent_tint(input.position, n);

    let NoL = dot(n_light, light_dir);
    let wrap = diffuse_wrap + select(0.0, 0.20 + 0.20 * sss_strength, is_foliage);
    let wrapped = max((NoL + wrap) / (1.0 + wrap), 0.0);

    var diffuse = albedo * wrapped * light_col * shadow * through_tint;
    if (is_foliage) {
        // Light bleeding through the leaf: the classic the reference backlit rim.
        let bleed = mu_sat(-NoL) * sss_strength * 0.35;
        diffuse = diffuse + albedo * vec3<f32>(0.68, 0.82, 0.26) * bleed * light_col * mu_sat(shadow + 0.2);
    }

    // Ambient: the sky's own colour, gated by the sky-light level, plus the
    // coloured block light the engine provides at this point.
    let sky_lin = mu_srgb_decode(frame.sky_color);
    let sky_tint = mix(vec3<f32>(mu_luma709(sky_lin)), sky_lin, 0.35);
    let sky_l = sqrt(mu_sat(input.light.y));
    let blk_l = mu_sat(input.light.x);
    let sky_amb = sky_tint * (0.70 * ambient_intensity) * (0.45 + 0.55 * max(n_light.y, 0.0));
    let tint4 = block_light_color(input.position);
    let blk_col = mix(vec3<f32>(1.0, 0.72, 0.50), tint4.rgb, mu_sat(tint4.a));
    let blk = blk_col * (1.8 * pow(blk_l, 2.6));
    let cave = vec3<f32>(0.010, 0.012, 0.018);
    // A small sky/ground floor keeps trunks and shaded sides readable instead
    // of printing them as black silhouettes, especially at distance.
    let ambient_floor = albedo * vec3<f32>(0.032, 0.030, 0.026) * (0.5 + 0.5 * max(n_light.y, 0.0));
    let bounce = albedo * vec3<f32>(0.055, 0.042, 0.024) * (0.5 - 0.5 * n_light.y) * max(sun.y, 0.0);
    let ambient = (sky_amb * sky_l + blk) * albedo + ambient_floor + bounce
        + cave * albedo * (1.0 - sky_l) * (1.0 - blk_l);

    let smoothness = mu_sat(specular_map.r);
    let roughness = clamp(1.0 - smoothness, 0.05, 1.0);
    let f0 = select(vec3<f32>(0.04), albedo, smoothness > 0.9);
    let specular = mu_specular(n, view, light_dir, roughness, f0)
        * light_col * shadow * through_tint * 2.0;

    let map_emission = select(specular_map.a, 0.0, specular_map.a > 0.998);
    let emissive = max(input.emission, map_emission);
    let emission = albedo * emissive * emission_strength;

    let occlusion = mix(1.0, normal_map.z, ao_strength);
    var color = (diffuse + ambient) * occlusion + specular + emission;
    color = max(color, vec3<f32>(0.0));

    // Distant LOD tiles and water/glass: return the right alpha for the alpha
    // test, and mark emissive surfaces so an HDR frame can pick them up.
    var alpha = input.albedo.a;
    if (!input.translucent && alpha > 0.9 && emissive > 0.0) {
        alpha = mix(0.38, 0.12, mu_sat(emissive));
    }
    return Surface(vec4<f32>(mu_scene_encode(color), alpha));
}
