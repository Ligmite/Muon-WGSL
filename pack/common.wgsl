// Muon (WGSL) - shared helpers. Placed before every stage.
// Pipeline convention: between passes the picture is stored encoded as
//   encoded = srgb_encode(scene_radiance / MU_HEADROOM)
// so that vanilla-drawn parts (entities, clouds, particles) and my terrain
// share one space. Every pass decodes, works in linear light, re-encodes.

override exposure_ev: f32 = 0.0;
override tonemap_op: u32 = 0u;
override grade_brightness: f32 = 1.02;
override grade_contrast: f32 = 1.12;
override grade_saturation: f32 = 1.22;
override grade_orange_boost: f32 = 0.10;
override grade_teal_boost: f32 = 0.00;
override grade_green_boost: f32 = 0.10;
override grade_green_hue: f32 = -4.0;
override vignette_intensity: f32 = 1.0;
override bloom_intensity: f32 = 1.0;
override bloom_spread: f32 = 1.0;
override bloom_threshold: f32 = 1.0;
override lens_flare: bool = true;
override lens_flare_intensity: f32 = 0.4;
override sun_intensity: f32 = 7.0;
override shadows_enabled: bool = true;
override shadow_softness: f32 = 1.0;
override shadow_strength: f32 = 1.0;
override diffuse_wrap: f32 = 0.25;
override sss_strength: f32 = 0.6;
override emission_strength: f32 = 2.5;
override water_waves: f32 = 1.0;
override water_speed: f32 = 1.2;
override water_fog: f32 = 1.0;
override water_fresnel: f32 = 0.85;
override water_refraction: f32 = 1.0;
override reflections: bool = true;
override ao_strength: f32 = 0.5;
override ao_radius: f32 = 2.0;
override ssr_mode: u32 = 1u;
override ssr_intensity: f32 = 1.0;
override vl_intensity: f32 = 0.6;
override fog_density: f32 = 0.50;
override sky_fog_blend: f32 = 0.03;
override sky_intensity: f32 = 1.0;
override sky_saturation: f32 = 1.2;
override hdr_enabled: bool = false;
override hdr_peak_nits: f32 = 1000.0;
override hdr_paper_white: f32 = 203.0;
override output_linear: bool = false;
override fxaa_enabled: bool = true;
override auto_exposure: u32 = 0u;
override ae_bias: f32 = 0.0;
override ae_min: f32 = -1.0;
override ae_max: f32 = 0.0;
override cas_enabled: bool = true;
override cas_intensity: f32 = 0.5;
override dither_enabled: bool = true;
override lut_enabled: bool = false;
override lut_strength: f32 = 1.0;
override underwater_density: f32 = 0.6;
override water_reflection_blur: f32 = 1.0;
override clouds_enabled: bool = true;
override ambient_intensity: f32 = 1.0;
override cloud_coverage: f32 = 0.42;
override cloud_density: f32 = 1.0;
override cloud_cumulus: f32 = 1.0;
override cloud_altocumulus: f32 = 0.15;
override cloud_cirrus: f32 = 0.18;

const MU_PI: f32 = 3.14159265;
// The inter-pass picture is sRGB-encoded with this much headroom. 2.0 clipped
// the sky: Rayleigh blue is several times brighter than the terrain, so the
// whole dome saturated to white. 4.0 keeps the blue and the cloud tops.
const MU_HEADROOM: f32 = 4.0;

const MU_709_TO_2020 = mat3x3<f32>(vec3<f32>(0.6274257, 0.3292891, 0.0433502), vec3<f32>(0.0690274, 0.9195786, 0.0113614), vec3<f32>(0.0163664, 0.0880289, 0.8956843));
const MU_2020_TO_709 = mat3x3<f32>(vec3<f32>(1.6603441, -0.5875716, -0.0728802), vec3<f32>(-0.1243787, 1.1328371, -0.0083587), vec3<f32>(-0.0181127, -0.1005838, 1.1186213));

fn mu_sat(x: f32) -> f32 { return clamp(x, 0.0, 1.0); }
fn mu_sat3(x: vec3<f32>) -> vec3<f32> { return clamp(x, vec3<f32>(0.0), vec3<f32>(1.0)); }
fn mu_max0(x: vec3<f32>) -> vec3<f32> { return max(x, vec3<f32>(0.0)); }
fn mu_sqr(x: f32) -> f32 { return x * x; }
fn mu_luma709(c: vec3<f32>) -> f32 { return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722)); }
fn mu_luma2020(c: vec3<f32>) -> f32 { return dot(c, vec3<f32>(0.2627, 0.6780, 0.0593)); }

// ---------------------------------------------------------------------
//   Transfer functions
// ---------------------------------------------------------------------

// Accurate sRGB, used for the inter-pass encoding (exactly invertible).
fn mu_srgb_encode(x: vec3<f32>) -> vec3<f32> {
    let c = max(x, vec3<f32>(0.0));
    let lo = c * 12.92;
    let hi = 1.055 * pow(c, vec3<f32>(1.0 / 2.4)) - vec3<f32>(0.055);
    return select(hi, lo, c < vec3<f32>(0.0031308));
}

fn mu_srgb_decode(x: vec3<f32>) -> vec3<f32> {
    let c = max(x, vec3<f32>(0.0));
    let lo = c / 12.92;
    let hi = pow((c + vec3<f32>(0.055)) / 1.055, vec3<f32>(2.4));
    return select(hi, lo, c < vec3<f32>(0.04045));
}

fn mu_scene_decode(encoded: vec3<f32>) -> vec3<f32> {
    return mu_srgb_decode(encoded) * MU_HEADROOM;
}

fn mu_scene_encode(radiance: vec3<f32>) -> vec3<f32> {
    return mu_srgb_encode(radiance / MU_HEADROOM);
}

// ---------------------------------------------------------------------
//   Colour grade
//
// A filmic grade of Muon (WGSL)'s own: exposure and log-contrast in scene-linear
// Rec.2020, then a gentle hue-aware saturation pass and a cool-shadow /
// warm-highlight split in the display domain. The published Lottes curve is
// the default tone map because its shoulder keeps sunlit sand and cloud tops
// from clipping.
// ---------------------------------------------------------------------

fn mu_cubic_smooth(x: f32) -> f32 { return x * x * (3.0 - 2.0 * x); }

fn mu_pulse(x_in: f32, center: f32, width: f32, period: f32) -> f32 {
    var x = (x_in - center + 0.5 * period) / period;
    x = fract(x) * period - 0.5 * period;
    let t = abs(x) / width;
    if (t > 1.0) { return 0.0; }
    return 1.0 - mu_cubic_smooth(t);
}

fn mu_rgb_to_hsl(c: vec3<f32>) -> vec3<f32> {
    let mx = max(c.r, max(c.g, c.b));
    let mn = min(c.r, min(c.g, c.b));
    let d = mx - mn;
    let e = 0.000001;
    var h = 0.0;
    if (d > e) {
        if (mx == c.r) {
            h = (c.g - c.b) / d;
            if (h < 0.0) { h = h + 6.0; }
        } else if (mx == c.g) {
            h = (c.b - c.r) / d + 2.0;
        } else {
            h = (c.r - c.g) / d + 4.0;
        }
        h = h / 6.0;
    }
    return vec3<f32>(h, d / (mx + e), mx);
}

fn mu_hsl_to_rgb(c: vec3<f32>) -> vec3<f32> {
    let sat = clamp(c.y, 0.0, 1.0);
    let val = clamp(c.z, 0.0, 1.0);
    let h = c.x;
    let pr = abs(fract(h + 1.0) * 6.0 - 3.0);
    let pg = abs(fract(h + 0.6666667) * 6.0 - 3.0);
    let pb = abs(fract(h + 0.3333333) * 6.0 - 3.0);
    let tr = clamp(pr - 1.0, 0.0, 1.0);
    let tg = clamp(pg - 1.0, 0.0, 1.0);
    let tb = clamp(pb - 1.0, 0.0, 1.0);
    let r = val * (1.0 + (tr - 1.0) * sat);
    let g = val * (1.0 + (tg - 1.0) * sat);
    let b = val * (1.0 + (tb - 1.0) * sat);
    return vec3<f32>(r, g, b);
}

fn mu_isolate_hue(hsl: vec3<f32>, center: f32, width: f32) -> f32 {
    if (hsl.y < 1e-2 || hsl.z < 1e-2) { return 0.0; }
    return mu_pulse(hsl.x * 360.0, center, width, 360.0);
}

// ---- dithering (ordered 16x16, 8 bit)
fn mu_bayer2(a: vec2<f32>) -> f32 {
    let f = floor(a);
    return fract(dot(f, vec2<f32>(0.5, f.y * 0.75)));
}
fn mu_bayer4(a: vec2<f32>) -> f32 { return 0.25 * mu_bayer2(0.5 * a) + mu_bayer2(a); }
fn mu_bayer8(a: vec2<f32>) -> f32 { return 0.25 * mu_bayer4(0.5 * a) + mu_bayer2(a); }
fn mu_bayer16(a: vec2<f32>) -> f32 { return 0.25 * mu_bayer8(0.5 * a) + mu_bayer2(a); }

// rgb: linear Rec.2020, [0, inf)
fn mu_grade_input(rgb_in: vec3<f32>) -> vec3<f32> {
    var rgb = mu_max0(rgb_in) * (0.85 * grade_brightness);

    // Contrast about the 18% grey point, in log2 space.
    let mid = log2(0.18);
    rgb = exp2(grade_contrast * (log2(max(rgb, vec3<f32>(1e-6))) - vec3<f32>(mid)) + vec3<f32>(mid));

    let lum = mu_luma2020(rgb);
    rgb = mu_max0(mix(vec3<f32>(lum), rgb, 0.98 * grade_saturation));
    return rgb;
}

// rgb: linear Rec.709 in [0, 1] (SDR) or Reinhard-compressed (HDR)
fn mu_grade_output(rgb_in: vec3<f32>) -> vec3<f32> {
    // Grade in a roughly perceptual domain.
    let rgb0 = sqrt(max(rgb_in, vec3<f32>(0.0)));
    var hsl = mu_rgb_to_hsl(rgb0);

    // Gentle hue bands: warm orange, cool teal, leafy green. The values are
    // Muon (WGSL)'s own, chosen against the same reference photographs as the rest.
    let orange = mu_isolate_hue(hsl, 32.0, 22.0);
    hsl.y = hsl.y * (1.0 + grade_orange_boost * orange);

    let teal = mu_isolate_hue(hsl, 200.0, 24.0);
    hsl.y = hsl.y * (1.0 + grade_teal_boost * teal);

    let green = mu_isolate_hue(hsl, 105.0, 44.0);
    hsl.x = hsl.x + (grade_green_hue / 360.0) * green;
    hsl.y = hsl.y * (1.0 + grade_green_boost * green);

    var rgb = mu_hsl_to_rgb(hsl);

    // Split tone: cool the shadows, warm the highlights. This is the part that
    // gives the picture depth instead of a flat mid-grey wash.
    let l = mu_luma709(rgb);
    let highs = smoothstep(0.30, 1.0, l);
    let shadows = 1.0 - smoothstep(0.0, 0.60, l);
    rgb = rgb * vec3<f32>(1.045, 1.00, 0.945);
    rgb = rgb * mix(vec3<f32>(0.95, 0.99, 1.06), vec3<f32>(1.19, 1.045, 0.83), highs);
    rgb = rgb * mix(1.0, 1.045, shadows);

    // A small S-curve for contrast and colour separation.
    rgb = mix(rgb, smoothstep(vec3<f32>(0.0), vec3<f32>(1.0), rgb), 0.12);

    return rgb * rgb;
}

fn mu_vignette(uv: vec2<f32>) -> f32 {
    let size = 16.0;
    let intensity = 0.08 * vignette_intensity;
    let t = abs(cos(2.0 * frame.time));
    let pulse = 1.0 - t * (2.0 - t);
    var v = size * (uv.x * uv.y - uv.x) * (uv.x * uv.y - uv.y);
    v = pow(max(v, 0.0), intensity + 0.3 * frame.blindness + 0.2 * pulse * frame.darkness);
    return v;
}

// ---------------------------------------------------------------------
//   Tonemapping operators (the reference + HDR fork)
// ---------------------------------------------------------------------

fn mu_tonemap_lottes(rgb: vec3<f32>) -> vec3<f32> {
    let a = 1.5;
    let d = 0.91;
    let hdr_max = 8.0;
    let mid_in = 0.26;
    let mid_out = 0.32;
    let b = (-pow(mid_in, a) + pow(hdr_max, a) * mid_out)
        / ((pow(hdr_max, a * d) - pow(mid_in, a * d)) * mid_out);
    let c = (pow(hdr_max, a * d) * pow(mid_in, a) - pow(hdr_max, a) * pow(mid_in, a * d) * mid_out)
        / ((pow(hdr_max, a * d) - pow(mid_in, a * d)) * mid_out);
    return pow(rgb, vec3<f32>(a)) / (pow(rgb, vec3<f32>(a * d)) * b + c);
}

fn mu_tonemap_hejl_burgess(rgb_in: vec3<f32>) -> vec3<f32> {
    var rgb = rgb_in * min(vec3<f32>(1.0), vec3<f32>(1.0) - 0.8 * exp(rgb_in * (-1.0 / 0.004)));
    rgb = (rgb * (6.2 * rgb + vec3<f32>(0.5))) / (rgb * (6.2 * rgb + vec3<f32>(1.7)) + vec3<f32>(0.06));
    return rgb * (rgb * (rgb * 0.305306011 + vec3<f32>(0.682171111)) + vec3<f32>(0.012522878));
}

fn mu_uncharted2_partial(x: vec3<f32>) -> vec3<f32> {
    let a = 0.15;
    let b = 0.50;
    let c = 0.10;
    let d = 0.20;
    let e = 0.02;
    let f = 0.30;
    return ((x * (a * x + vec3<f32>(c * b)) + vec3<f32>(d * e)) / (x * (a * x + vec3<f32>(b)) + vec3<f32>(d * f))) - vec3<f32>(e / f);
}

fn mu_tonemap_uncharted2(rgb: vec3<f32>) -> vec3<f32> {
    let curr = mu_uncharted2_partial(rgb * 2.0);
    let white_scale = vec3<f32>(1.0) / mu_uncharted2_partial(vec3<f32>(11.2));
    return curr * white_scale;
}

fn mu_tonemap_tech(rgb: vec3<f32>) -> vec3<f32> {
    var a = rgb * min(vec3<f32>(1.0), vec3<f32>(1.0) - exp(rgb * (-1.0 / 0.038)));
    a = mix(a, rgb, rgb * rgb);
    return a / (a + vec3<f32>(0.6));
}

fn mu_tonemap_reinhard_jodie(rgb: vec3<f32>) -> vec3<f32> {
    let r = rgb / (rgb + vec3<f32>(1.0));
    return mix(rgb / (mu_luma2020(rgb) + 1.0), r, r);
}

fn mu_tonemap_sdr(rgb: vec3<f32>) -> vec3<f32> {
    let x = mu_max0(rgb);
    if (tonemap_op == 1u) { return mu_tonemap_hejl_burgess(x); }
    if (tonemap_op == 2u) { return mu_tonemap_uncharted2(x); }
    if (tonemap_op == 3u) { return mu_tonemap_tech(x); }
    if (tonemap_op == 4u) { return mu_tonemap_reinhard_jodie(x); }
    return mu_tonemap_lottes(x);
}

// HDR: keep the filmic SDR curve in the toe and hand the highlights to a soft
// exponential shoulder at the display's peak, relative to paper white. The
// approach follows the the reference HDR fork; the implementation is Muon (WGSL)'s own.
fn mu_hdr_shoulder(rgb: vec3<f32>, peak: f32) -> vec3<f32> {
    let x = mu_max0(rgb);
    let lottes = mu_tonemap_lottes(x);
    let shoulder = peak * (vec3<f32>(1.0) - exp(-x / max(peak, 0.01)));
    let blend = smoothstep(0.45, 1.0, mu_luma2020(x));
    return mix(lottes, shoulder, blend);
}

fn mu_tonemap_hdr(rgb_in: vec3<f32>) -> vec3<f32> {
    let peak = max(hdr_peak_nits / hdr_paper_white, 1.0);
    if (tonemap_op == 2u) {
        return mu_hdr_shoulder(mu_tonemap_uncharted2(mu_max0(rgb_in)), peak);
    }
    return mu_hdr_shoulder(mu_max0(rgb_in), peak);
}

fn mu_reinhard(x: vec3<f32>) -> vec3<f32> { return x / (x + vec3<f32>(1.0)); }
fn mu_reinhard_inverse(x: vec3<f32>) -> vec3<f32> { return x / max(vec3<f32>(1.0) - x, vec3<f32>(1e-4)); }

// ---------------------------------------------------------------------
//   Atmosphere (single scattering, quadratic step distribution)
// ---------------------------------------------------------------------

fn mu_ray_sphere_far(ro: vec3<f32>, rd: vec3<f32>, r: f32) -> f32 {
    let b = dot(ro, rd);
    let c = dot(ro, ro) - r * r;
    let disc = b * b - c;
    if (disc < 0.0) { return -1.0; }
    return -b + sqrt(disc);
}

// Radiance of the sky along `dir` for a light at `sun`, in scene units.
fn mu_atmosphere(dir_in: vec3<f32>, sun: vec3<f32>, steps: i32) -> vec3<f32> {
    let planet = 6371.0;
    let top = 6471.0;
    let h_r = 8.0;
    let h_m = 1.2;
    let beta_r = vec3<f32>(5.8e-3, 13.5e-3, 33.1e-3);
    let beta_m = 21e-3;

    let d = normalize(vec3<f32>(dir_in.x, max(dir_in.y, 0.004), dir_in.z));
    let ro = vec3<f32>(0.0, planet + 0.2, 0.0);
    let t_max = mu_ray_sphere_far(ro, d, top);
    if (t_max < 0.0) { return vec3<f32>(0.0); }

    var opt_r = 0.0;
    var opt_m = 0.0;
    var sum_r = vec3<f32>(0.0);
    var sum_m = vec3<f32>(0.0);
    let n = f32(steps);

    for (var i = 0; i < steps; i = i + 1) {
        let u = (f32(i) + 0.5) / n;
        let ds = t_max * 2.0 * u / n;
        let p = ro + d * (t_max * u * u);
        let h = length(p) - planet;
        let dr = exp(-h / h_r) * ds;
        let dm = exp(-h / h_m) * ds;
        opt_r = opt_r + dr;
        opt_m = opt_m + dm;

        let tl = mu_ray_sphere_far(p, sun, top);
        let lds = max(tl, 0.0) / 4.0;
        var lr = 0.0;
        var lm = 0.0;
        for (var j = 0; j < 4; j = j + 1) {
            let q = p + sun * (lds * (f32(j) + 0.5));
            let hq = length(q) - planet;
            lr = lr + exp(-hq / h_r) * lds;
            lm = lm + exp(-hq / h_m) * lds;
        }
        let tau = beta_r * (opt_r + lr) + vec3<f32>(beta_m * 1.1 * (opt_m + lm))
            + vec3<f32>(0.65e-3, 1.881e-3, 0.085e-3) * (1.5 * (opt_r + lr));
        let att = exp(-tau);
        sum_r = sum_r + att * dr;
        sum_m = sum_m + att * dm;
    }

    let mu = dot(d, sun);
    let g = 0.76;
    let phase_r = 3.0 / (16.0 * MU_PI) * (1.0 + mu * mu);
    let phase_m = 3.0 / (8.0 * MU_PI) * ((1.0 - g * g) * (1.0 + mu * mu))
        / ((2.0 + g * g) * pow(1.0 + g * g - 2.0 * g * mu, 1.5));
    return 6.00 * (sum_r * beta_r * phase_r + sum_m * (beta_m * phase_m));
}

// Full sky: sun scattering plus a faint moon-lit night sky.
//
// Single scattering alone leaves the horizon several times too dark: the
// last few degrees of a real sky are mostly light that has scattered more
// than once. A broad horizon term stands in for that missing order, and it
// is also what gives the water, the clouds and the distance fog a horizon
// colour to blend toward.
fn mu_sky_radiance(dir: vec3<f32>, steps: i32) -> vec3<f32> {
    var c = mu_atmosphere(dir, frame.sun_direction, steps);
    c = c + mu_atmosphere(dir, frame.moon_direction, max(steps / 2, 4)) * vec3<f32>(0.0030, 0.0040, 0.0070);
    c = c + vec3<f32>(0.0008, 0.0012, 0.0028);

    let day = smoothstep(-0.10, 0.12, frame.sun_direction.y);
    let horizon = 1.0 - smoothstep(0.0, 0.34, max(dir.y, 0.0));
    let sun_mu = mu_sat(dot(dir, frame.sun_direction));
    let warm = pow(sun_mu, 5.0);
    let haze = vec3<f32>(0.055, 0.095, 0.185)
        + mu_sun_color(frame.sun_direction.y) * (0.16 * warm + 0.04);
    c = c + haze * (horizon * horizon) * day;
    return c;
}

// Cheap sun colour (direct light), warmer near the horizon.
fn mu_sun_color(sun_y: f32) -> vec3<f32> {
    let warm = vec3<f32>(1.00, 0.42, 0.14);
    let white = vec3<f32>(1.00, 0.91, 0.76);
    let vis = smoothstep(-0.06, 0.10, sun_y);
    return mix(warm, white, smoothstep(0.02, 0.40, sun_y)) * vis;
}

fn mu_moon_color(moon_y: f32) -> vec3<f32> {
    return vec3<f32>(0.40, 0.52, 0.90) * 0.035 * smoothstep(-0.08, 0.12, moon_y);
}

// Camera-relative world position -> (uv.xy, reversed depth). z < 0 when behind camera.
fn mu_project(p: vec3<f32>) -> vec3<f32> {
    let v = frame.view * vec4<f32>(p, 1.0);
    let c = frame.projection * v;
    if (c.w <= 0.000001) { return vec3<f32>(-10.0, -10.0, -10.0); }
    let ndc = c.xyz / c.w;
    return vec3<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5, ndc.z);
}

fn mu_ign(p: vec2<f32>, i: u32) -> f32 {
    let q = p + vec2<f32>(5.588238 * f32(i % 64u));
    return fract(52.9829189 * fract(dot(q, vec2<f32>(0.06711056, 0.00583715))));
}

fn mu_hash3(p: vec3<f32>) -> f32 {
    var q = fract(p * 0.1031);
    q = q + vec3<f32>(dot(q, q.zyx + vec3<f32>(31.32)));
    return fract((q.x + q.y) * q.z);
}

fn mu_hash2(p: vec2<f32>) -> f32 {
    var q = fract(vec3<f32>(p.x, p.y, p.x) * vec3<f32>(0.1031, 0.1030, 0.0973));
    q = q + vec3<f32>(dot(q, q.yzx + vec3<f32>(31.32)));
    return fract((q.x + q.y) * q.z);
}

fn mu_noise2(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (vec2<f32>(3.0) - 2.0 * f);
    let a = mu_hash2(i);
    let b = mu_hash2(i + vec2<f32>(1.0, 0.0));
    let c = mu_hash2(i + vec2<f32>(0.0, 1.0));
    let d = mu_hash2(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn mu_fbm2(p0: vec2<f32>, octaves: i32) -> f32 {
    var p = p0;
    var sum = 0.0;
    var amp = 0.5;
    var norm = 0.0;
    for (var i = 0; i < 6; i = i + 1) {
        if (i >= octaves) { break; }
        sum = sum + amp * mu_noise2(p);
        norm = norm + amp;
        p = p * 2.03 + vec2<f32>(17.3, 9.1);
        amp = amp * 0.5;
    }
    return sum / max(norm, 1e-5);
}

fn mu_noise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (vec3<f32>(3.0) - 2.0 * f);
    let n000 = mu_hash3(i);
    let n100 = mu_hash3(i + vec3<f32>(1.0, 0.0, 0.0));
    let n010 = mu_hash3(i + vec3<f32>(0.0, 1.0, 0.0));
    let n110 = mu_hash3(i + vec3<f32>(1.0, 1.0, 0.0));
    let n001 = mu_hash3(i + vec3<f32>(0.0, 0.0, 1.0));
    let n101 = mu_hash3(i + vec3<f32>(1.0, 0.0, 1.0));
    let n011 = mu_hash3(i + vec3<f32>(0.0, 1.0, 1.0));
    let n111 = mu_hash3(i + vec3<f32>(1.0, 1.0, 1.0));
    let x00 = n000 + (n100 - n000) * u.x;
    let x10 = n010 + (n110 - n010) * u.x;
    let x01 = n001 + (n101 - n001) * u.x;
    let x11 = n011 + (n111 - n011) * u.x;
    let y0 = x00 + (x10 - x00) * u.y;
    let y1 = x01 + (x11 - x01) * u.y;
    return y0 + (y1 - y0) * u.z;
}

fn mu_hg(mu: f32, g: f32) -> f32 {
    let g2 = g * g;
    return (1.0 - g2) / (4.0 * MU_PI * pow(1.0 + g2 - 2.0 * g * mu, 1.5));
}

// 0 in fair weather, 1 in rain; thunder adds on top.
fn mu_wetness() -> f32 { return mu_sat(max(frame.rain, frame.thunder)); }

// Billowy 3D noise: folding around the midpoint gives cloud tops their
// cauliflower silhouette instead of the soft blobs plain fbm produces.
fn mu_billow3(p0: vec3<f32>, octaves: i32) -> f32 {
    var p = p0;
    var sum = 0.0;
    var amp = 0.5;
    var norm = 0.0;
    for (var i = 0; i < 5; i = i + 1) {
        if (i >= octaves) { break; }
        let n = abs(mu_noise3(p) * 2.0 - 1.0);
        sum = sum + (1.0 - n) * amp;
        norm = norm + amp;
        p = p * 2.11 + vec3<f32>(3.1, 7.7, 13.3);
        amp = amp * 0.5;
    }
    return sum / max(norm, 1e-5);
}

// ---------------------------------------------------------------------
//   Sky helpers shared by the clouds, the water and the distance fog
// ---------------------------------------------------------------------

// A cheap horizon colour, in scene units. The cloud and fog passes call
// this instead of marching the full atmosphere for every sample.
fn mu_sky_horizon(dir_in: vec3<f32>) -> vec3<f32> {
    let d = normalize(vec3<f32>(dir_in.x, 0.045, dir_in.z));
    var c = mu_sky_radiance(d, 5);
    let mu = mu_sat(dot(d, frame.sun_direction));
    c = c + mu_sun_color(frame.sun_direction.y) * (0.03 * pow(mu, 8.0));
    // A short single-scattering integral reads paler than the full 12-step
    // dome at grazing angles. Pull the reflection/fog colour back toward the
    // zenith blue so the horizon does not become a white sheet.
    c = c * vec3<f32>(0.78, 0.90, 1.16);
    return c;
}

// Exponential height fog integrated along a ray. `dist` is in blocks. The
// result is capped so the far LOD is hazed, not erased: the cap leaves at
// least a third of the direct light at the far plane.
fn mu_aerial_fog(cam: vec3<f32>, dir: vec3<f32>, dist: f32, color: vec3<f32>) -> vec3<f32> {
    let wet = mu_sat(frame.rain * 0.7 + frame.thunder * 0.3);
    let density = 0.0032 * fog_density * (1.0 + 1.8 * wet);
    let scale_h = 135.0;
    let h = max(cam.y - 63.0, 0.0);
    let k = 1.0 / scale_h;
    var od = 0.0;
    let dy = dir.y;
    if (abs(dy) > 1e-4) {
        od = density * exp(-h * k) * (1.0 - exp(-dist * dy * k)) / max(dy * k, 1e-5);
    } else {
        od = density * exp(-h * k) * dist;
    }
    od = clamp(od, 0.0, 1.15);
    let trans = exp(-od);

    // In-scatter: the horizon's own colour plus a forward Mie lobe around
    // the sun, so the haze warms toward the light instead of greying out.
    let sky = mu_sky_horizon(dir);
    let sun = frame.sun_direction;
    let day = smoothstep(-0.06, 0.12, sun.y);
    let mu = dot(dir, sun);
    let lobe = 0.45 + 0.55 * mu_sat(mu);
    let sun_haze = mu_sun_color(sun.y) * (0.55 * mu_hg(mu, 0.55) * 6.0 * day * lobe);
    let warm = 0.35 + 0.65 * pow(mu_sat(mu * 0.5 + 0.5), 3.0);
    let inscatter = (sky * (0.60 + 0.25 * warm) + sun_haze * vec3<f32>(warm, warm * 0.9, warm * 0.75))
        * vec3<f32>(1.055, 1.005, 0.925);
    return color * trans + inscatter * (1.0 - trans);
}

// ---------------------------------------------------------------------
//   Clouds: three layers
//
// Photon draws a stack of cloud layers, each with its own altitude and
// shape. Muon (WGSL) does the same with its own fields: a volumetric cumulus /
// stratocumulus deck, a thin altocumulus deck above it and a planar
// cirrus sheet. All three live in world space, so walking moves them only
// by their real parallax; the layers are high enough that this reads as
// sky motion rather than a ceiling sliding past.
// ---------------------------------------------------------------------

const MU_CUMULUS_BASE: f32 = 1000.0;
const MU_CUMULUS_THICK: f32 = 300.0;
const MU_ALTO_BASE: f32 = 2800.0;
const MU_ALTO_THICK: f32 = 200.0;
const MU_CIRRUS_ALT: f32 = 5600.0;

struct MuCloudLayer {
    scatter: vec3<f32>,
    trans: f32,
    dist: f32,
};

fn mu_cloud_layer_empty() -> MuCloudLayer {
    return MuCloudLayer(vec3<f32>(0.0), 1.0, 1.0e6);
}

// 2D coverage charts. Each chart is its own field: a large-scale fBm with a
// small domain warp, plus a finer term that tears the edge. The warp is
// what stops the coverage looking like a blurred Perlin sheet.
fn mu_cloud_chart(p: vec2<f32>, scale: f32, seed: vec2<f32>, warp: f32) -> f32 {
    let q = p * scale + seed;
    let w = vec2<f32>(
        mu_noise2(q * 0.55 + vec2<f32>(13.7, 4.1)),
        mu_noise2(q * 0.55 + vec2<f32>(7.3, 21.9))
    ) - vec2<f32>(0.5);
    let big = mu_fbm2(q + w * warp, 3);
    let fine = mu_fbm2(q * 3.1 + vec2<f32>(5.0, 11.0) + w * warp * 1.7, 2);
    return mu_sat(big * 0.82 + fine * 0.18);
}

fn mu_cumulus_chart(p: vec2<f32>, t: f32) -> f32 {
    let wind = vec2<f32>(t * 2.4, t * 0.9);
    return mu_cloud_chart(p + wind, 0.00105, vec2<f32>(3.0, 7.0), 0.9);
}

fn mu_altocumulus_chart(p: vec2<f32>, t: f32) -> f32 {
    let wind = vec2<f32>(t * 3.8, t * 1.6);
    return mu_cloud_chart(p + wind, 0.0027, vec2<f32>(11.0, 2.0), 0.65);
}

// Each column has its own base and thickness. This is the vertical break-up
// that keeps a layer from reading as a painted ceiling.
fn mu_cloud_column(p: vec2<f32>, t: f32) -> vec2<f32> {
    let a = mu_noise2(p * 0.0011 + vec2<f32>(t * 0.006, 4.0));
    let b = mu_noise2(p * 0.00085 + vec2<f32>(9.0, t * 0.0045));
    return vec2<f32>((a - 0.5) * 170.0, 0.72 + 0.56 * b);
}

// ---------------------------------------------------------------------
//   Cumulus / stratocumulus
// ---------------------------------------------------------------------

fn mu_cumulus_density(p: vec3<f32>, base: f32, thick: f32, coverage: f32) -> f32 {
    let t = frame.time;
    let col = mu_cloud_column(p.xz, t);
    let h = (p.y - base - col.x) / max(thick * col.y, 64.0);
    if (h <= 0.0 || h >= 1.0) { return 0.0; }

    let chart = mu_cumulus_chart(p.xz, t);
    let thr = mix(0.70, 0.44, coverage);

    // Coverage in 3D: the same column can survive at one altitude and be
    // eroded at another, which is what stops the deck reading as an
    // extruded 2D mask.
    let cov3 = mu_noise3(p * vec3<f32>(0.0032, 0.0055, 0.0032)
                         + vec3<f32>(t * 0.035, 0.0, t * 0.018)) - 0.5;
    let mask = smoothstep(thr + h * 0.10, thr + h * 0.10 + 0.15, chart + cov3 * 0.34);

    // Cauliflower tops: folded billow noise, then a finer erosion pass.
    let q = vec3<f32>(p.x + t * 1.8, p.y * 0.9, p.z + t * 0.7) * 0.0036;
    let billow = mu_billow3(q, 3);
    let q2 = vec3<f32>(p.x - t * 0.9, p.y * 1.7, p.z + t * 0.5) * 0.0125;
    let erode = mu_billow3(q2, 2);
    let edge = smoothstep(0.28, 0.68, billow);
    let detail = edge * mix(0.50, 1.0, erode);

    // Egg profile: thin at the base, dense in the middle, soft at the top.
    let profile = smoothstep(0.0, 0.16, h) * (1.0 - smoothstep(0.58, 1.0, h));
    let egg = smoothstep(0.22, 0.88, h) * 0.30;
    var d = max(mask * detail * profile - egg * 0.16, 0.0);

    // In overcast weather the same field becomes a stratiform sheet: fill
    // the gaps and flatten the top instead of a deck of separate puffs.
    let stratus = smoothstep(0.62, 0.94, coverage);
    if (stratus > 0.001) {
        let sheet = smoothstep(0.30, 0.58, chart)
            * smoothstep(0.02, 0.16, h) * (1.0 - smoothstep(0.74, 1.0, h));
        d = max(d, sheet * 0.62 * stratus);
    }

    return d * cloud_density * cloud_cumulus;
}

// ---------------------------------------------------------------------
//   Altocumulus / altostratus
// ---------------------------------------------------------------------

fn mu_altocumulus_density(p: vec3<f32>, base: f32, thick: f32, coverage: f32) -> f32 {
    let t = frame.time;
    let h = (p.y - base) / thick;
    if (h <= 0.0 || h >= 1.0) { return 0.0; }
    if (cloud_altocumulus <= 0.001) { return 0.0; }

    let wind = vec2<f32>(t * 3.8, t * 1.6);
    let chart = mu_altocumulus_chart(p.xz, t);
    let thr = mix(0.72, 0.46, coverage);
    var d = smoothstep(thr, thr + 0.11, chart);

    // Mackerel-sky cells and a soft 3D erosion. The cells are the visual
    // difference between this layer and the cumulus below it; a slowly
    // varying warp keeps value noise's square cells from reading as a grid.
    let cell_warp = vec2<f32>(
        mu_noise2(p.xz * 0.0016 + vec2<f32>(t * 0.01, 2.0)),
        mu_noise2(p.xz * 0.0016 + vec2<f32>(7.0, t * 0.008))
    ) - vec2<f32>(0.5);
    let cells = mu_fbm2((p.xz + wind * 1.3) * 0.006 + cell_warp * 0.055 + vec2<f32>(4.0, 9.0), 3);
    d = d * smoothstep(0.24, 0.66, cells);
    let patches = smoothstep(0.36, 0.66,
        mu_fbm2(p.xz * 0.0011 + vec2<f32>(13.0, 5.0), 2));
    d = d * mix(0.55, 1.0, patches);
    let detail = mu_noise3(p * 0.006 + vec3<f32>(t * 0.05, 0.0, t * 0.02)) - 0.5;
    d = max(d + detail * 0.16, 0.0);

    let profile = smoothstep(0.0, 0.20, h) * (1.0 - smoothstep(0.62, 1.0, h));
    return d * profile * cloud_density * cloud_altocumulus * 0.62;
}

// ---------------------------------------------------------------------
//   Cirrus / cirrostratus
// ---------------------------------------------------------------------

fn mu_cirrus_density(p: vec2<f32>, t: f32) -> f32 {
    let wind = vec2<f32>(t * 4.4, t * 1.8);
    let q = (p + wind) * vec2<f32>(0.00055, 0.0018);
    let w = vec2<f32>(
        mu_noise2(q * 0.60 + vec2<f32>(3.0, 9.0)),
        mu_noise2(q * 0.60 + vec2<f32>(17.0, 1.0))
    ) - vec2<f32>(0.5);

    // Fibrous streaks: the anisotropic coordinate is what makes them read
    // as cirrus rather than as another fBm cloud.
    let n = mu_fbm2(q + w * 1.35, 4);
    let streak = smoothstep(0.46, 0.68, n);
    let veil = smoothstep(0.36, 0.58, mu_fbm2(q * 0.55 + vec2<f32>(7.0, 2.0) + w * 0.8, 3));
    var d = max(streak, veil * 0.34);
    let detail = smoothstep(0.26, 0.68, mu_fbm2(q * 4.5 + w * 2.0 + vec2<f32>(5.0), 2));
    d = d * mix(0.35, 1.0, detail);
    return d * cloud_cirrus;
}

// ---------------------------------------------------------------------
//   Cloud lighting
// ---------------------------------------------------------------------

fn mu_cloud_phase(c: f32) -> f32 {
    // A forward lobe for the lit edge and a small back lobe so the shaded
    // side does not turn into a flat grey wall.
    return 0.72 * mu_hg(c, 0.62) + 0.28 * mu_hg(c, -0.22);
}

fn mu_cloud_density_at(p: vec3<f32>, base: f32, thick: f32, coverage: f32, kind: u32) -> f32 {
    if (kind == 0u) { return mu_cumulus_density(p, base, thick, coverage); }
    return mu_altocumulus_density(p, base, thick, coverage);
}

fn mu_cloud_lighting(
    p: vec3<f32>,
    density: f32,
    base: f32,
    thick: f32,
    coverage: f32,
    kind: u32,
    cos_theta: f32,
    height01: f32
) -> vec3<f32> {
    let sun = frame.sun_direction;
    let moon = frame.moon_direction;
    let day = smoothstep(-0.08, 0.12, sun.y);
    let moonlit = sun.y < -0.02;
    let light_dir = select(sun, moon, moonlit);

    // Two expanding samples toward the light. The short march is enough to
    // separate a sunlit top from a shaded base; the multi-scatter sum does
    // the rest of the work.
    var od = density * 0.55;
    var step = 16.0;
    var q = p;
    if (kind == 0u) {
        for (var i = 0; i < 2; i = i + 1) {
            q = q + light_dir * step;
            od = od + mu_cloud_density_at(q, base, thick, coverage, kind) * step * 0.050;
            step = step * 2.0;
        }
    } else {
        q = q + light_dir * step;
        od = od + mu_cloud_density_at(q, base, thick, coverage, kind) * step * 0.040;
    }
    let beer = exp(-od);
    let powder = 1.0 - exp(-od * 2.4);

    // Four-term multiple scattering: each pass is dimmer, less extinct and
    // more isotropic. This is what keeps thick cores from going black.
    var ms = 0.0;
    var amp = 1.0;
    var ext = od;
    var g = 0.62;
    for (var i = 0; i < 4; i = i + 1) {
        let phase = 0.70 * mu_hg(cos_theta, g) + 0.30 * mu_hg(cos_theta, -g * 0.35);
        ms = ms + amp * exp(-ext) * phase;
        amp = amp * 0.45;
        ext = ext * 0.32;
        g = g * 0.58;
    }

    let sky_lin = mu_srgb_decode(mix(frame.fog_color, frame.sky_color, 0.55));
    let sky_amb = mix(vec3<f32>(mu_luma709(sky_lin)), sky_lin, 0.42);
    let wet = mu_sat(frame.rain * 0.8 + frame.thunder * 0.5);
    let ambient = sky_amb * (0.58 + 0.42 * day) * (0.65 + 0.35 * height01)
        * (1.0 - 0.28 * wet);
    let sun_col = select(mu_moon_color(moon.y) * 7.0, mu_sun_color(sun.y) * 5.0, day > 0.0);
    let direct = sun_col * (ms * 0.90 + beer * 0.20)
        * (0.45 + 0.55 * powder) * mix(0.62, 1.0, height01)
        * (1.0 - 0.55 * wet);
    return ambient + direct;
}

fn mu_cirrus_lighting(cos_theta: f32, density: f32) -> vec3<f32> {
    let sun = frame.sun_direction;
    let moon = frame.moon_direction;
    let day = smoothstep(-0.08, 0.12, sun.y);
    let phase = mu_cloud_phase(cos_theta);
    let sun_col = select(mu_moon_color(moon.y) * 5.0, mu_sun_color(sun.y) * 3.4, day > 0.0);
    let sky_disp = mix(frame.fog_color, frame.sky_color, 0.65);
    let sky_lin = mu_srgb_decode(sky_disp);
    let ambient = mix(vec3<f32>(mu_luma709(sky_lin)), sky_lin, 0.40)
        * (0.55 + 0.40 * day);
    let thin = 1.0 - exp(-density * 3.0);
    return ambient + sun_col * phase * (0.55 + 0.45 * thin);
}

// ---------------------------------------------------------------------
//   Layer march
// ---------------------------------------------------------------------

fn mu_cumulus_layer(
    origin: vec3<f32>,
    dir: vec3<f32>,
    max_dist: f32,
    base: f32,
    thick: f32,
    coverage: f32,
    steps: i32,
    air_sky: vec3<f32>
) -> MuCloudLayer {
    if (abs(dir.y) < 1.0e-4) { return mu_cloud_layer_empty(); }
    let tb = (base - origin.y) / dir.y;
    let tt = (base + thick - origin.y) / dir.y;
    var t0 = max(min(tb, tt), 0.0);
    var t1 = min(max(tb, tt), max_dist);
    if (t1 <= t0) { return mu_cloud_layer_empty(); }

    // A shallow ray crosses a mountain range of deck; cap the march and fade
    // the samples before the cutoff so it never becomes a hard edge.
    let max_len = 7200.0;
    t1 = min(t1, t0 + max_len);
    let n = f32(steps);
    let step_len = (t1 - t0) / n;
    let jitter = mu_hash3(dir * 811.0);
    var t = t0 + step_len * jitter;
    var trans = 1.0;
    var scattered = vec3<f32>(0.0);
    var dist_sum = 0.0;
    var weight_sum = 0.0;
    let cos_theta = dot(dir, frame.light_direction);

    for (var i = 0; i < steps; i = i + 1) {
        if (trans < 0.015) { break; }
        let p = origin + dir * t;
        let col = mu_cloud_column(p.xz, frame.time);
        let h = mu_sat((p.y - base - col.x) / max(thick * col.y, 64.0));
        var density = mu_cumulus_density(p, base, thick, coverage);
        let travelled = t - t0;
        density = density * (1.0 - smoothstep(0.84, 1.0, travelled / max_len));
        if (density > 0.002) {
            let lit = mu_cloud_lighting(p, density, base, thick, coverage, 0u, cos_theta, h);
            let ext = density * 0.105 * step_len;
            let st = exp(-ext);
            scattered = scattered + trans * (1.0 - st) * lit;
            trans = trans * st;
            dist_sum = dist_sum + t * density;
            weight_sum = weight_sum + density;
        }
        t = t + step_len;
    }

    let air = exp(-t0 * 0.00026);
    scattered = mix((1.0 - trans) * air_sky, scattered, air);
    let dist = select(t0 + dist_sum / max(weight_sum, 1.0e-4), t0, weight_sum < 1.0e-4);
    return MuCloudLayer(scattered, trans, dist);
}

fn mu_altocumulus_layer(
    origin: vec3<f32>,
    dir: vec3<f32>,
    max_dist: f32,
    base: f32,
    thick: f32,
    coverage: f32,
    steps: i32,
    air_sky: vec3<f32>
) -> MuCloudLayer {
    if (abs(dir.y) < 1.0e-4) { return mu_cloud_layer_empty(); }
    let tb = (base - origin.y) / dir.y;
    let tt = (base + thick - origin.y) / dir.y;
    var t0 = max(min(tb, tt), 0.0);
    var t1 = min(max(tb, tt), max_dist);
    if (t1 <= t0) { return mu_cloud_layer_empty(); }
    let max_len = 9000.0;
    t1 = min(t1, t0 + max_len);
    let n = f32(steps);
    let step_len = (t1 - t0) / n;
    let jitter = mu_hash3(dir * 419.0);
    var t = t0 + step_len * jitter;
    var trans = 1.0;
    var scattered = vec3<f32>(0.0);
    var dist_sum = 0.0;
    var weight_sum = 0.0;
    let cos_theta = dot(dir, frame.light_direction);

    for (var i = 0; i < steps; i = i + 1) {
        if (trans < 0.02) { break; }
        let p = origin + dir * t;
        let h = mu_sat((p.y - base) / thick);
        var density = mu_altocumulus_density(p, base, thick, coverage);
        let travelled = t - t0;
        density = density * (1.0 - smoothstep(0.86, 1.0, travelled / max_len));
        if (density > 0.002) {
            let lit = mu_cloud_lighting(p, density, base, thick, coverage, 1u, cos_theta, h);
            let ext = density * 0.070 * step_len;
            let st = exp(-ext);
            scattered = scattered + trans * (1.0 - st) * lit;
            trans = trans * st;
            dist_sum = dist_sum + t * density;
            weight_sum = weight_sum + density;
        }
        t = t + step_len;
    }

    let air = exp(-t0 * 0.00022);
    scattered = mix((1.0 - trans) * air_sky, scattered, air);
    let dist = select(t0 + dist_sum / max(weight_sum, 1.0e-4), t0, weight_sum < 1.0e-4);
    return MuCloudLayer(scattered, trans, dist);
}

fn mu_cirrus_layer(origin: vec3<f32>, dir: vec3<f32>, max_dist: f32, air_sky: vec3<f32>) -> MuCloudLayer {
    if (cloud_cirrus <= 0.001 || abs(dir.y) <= 0.002) { return mu_cloud_layer_empty(); }
    let t = (MU_CIRRUS_ALT - origin.y) / dir.y;
    if (t <= 0.0 || t > max_dist) { return mu_cloud_layer_empty(); }
    let p = origin + dir * t;
    let density = mu_cirrus_density(p.xz, frame.time);
    if (density < 0.002) { return mu_cloud_layer_empty(); }
    let cos_theta = dot(dir, frame.light_direction);
    let lit = mu_cirrus_lighting(cos_theta, density);
    let od = density * 0.72 / max(abs(dir.y), 0.04);
    let trans = exp(-od);
    var scattered = (1.0 - trans) * lit;
    let air = exp(-t * 0.00018);
    scattered = mix((1.0 - trans) * air_sky, scattered, air);
    return MuCloudLayer(scattered, trans, t);
}

// Composite three layers from the nearest to the farthest. The distances are
// compared rather than assuming an order, so flying above the deck still
// draws the layers the right way round.
fn mu_cloud_composite(a: MuCloudLayer, b: MuCloudLayer, c: MuCloudLayer) -> vec4<f32> {
    var layers = array<MuCloudLayer, 3>(a, b, c);
    for (var i = 0u; i < 2u; i = i + 1u) {
        for (var j = 0u; j < 2u - i; j = j + 1u) {
            if (layers[j].dist > layers[j + 1u].dist) {
                let tmp = layers[j];
                layers[j] = layers[j + 1u];
                layers[j + 1u] = tmp;
            }
        }
    }
    var color = vec3<f32>(0.0);
    var trans = 1.0;
    for (var i = 0u; i < 3u; i = i + 1u) {
        color = color + trans * layers[i].scatter;
        trans = trans * layers[i].trans;
    }
    return vec4<f32>(color, trans);
}

// Project the point toward the sun onto the cumulus base and read the
// coverage chart there. Cheap dappled light, and the reason a broken deck
// reads as weather instead of a painted backdrop.
fn mu_cloud_shadow(world_pos: vec3<f32>) -> f32 {
    let sun = frame.sun_direction;
    if (sun.y <= 0.05) { return 1.0; }
    let wet = mu_wetness();
    let coverage = clamp(cloud_coverage + 0.30 * wet, 0.0, 1.0);
    let thr = mix(0.70, 0.44, coverage);

    let t = (MU_CUMULUS_BASE - world_pos.y) / sun.y;
    if (t > 0.0) {
        let p = world_pos.xz + sun.xz * t;
        let m = smoothstep(thr, thr + 0.18, mu_cumulus_chart(p, frame.time));
        let t2 = (MU_ALTO_BASE - world_pos.y) / max(sun.y, 0.12);
        let p2 = world_pos.xz + sun.xz * t2;
        let m2 = smoothstep(thr + 0.05, thr + 0.22, mu_altocumulus_chart(p2, frame.time));
        return 1.0 - max(m, m2 * 0.55) * 0.55;
    }
    return 1.0;
}

// Volumetric clouds. The layers are anchored in the world (the camera is the
// ray origin), so walking moves them by their true parallax. The interval is
// intersected generically, which lets the post pass draw the deck from above
// as well as from below.
fn mu_clouds(origin: vec3<f32>, dir: vec3<f32>, max_dist: f32) -> vec4<f32> {
    let wet = mu_wetness();
    let coverage = clamp(cloud_coverage + 0.30 * wet, 0.0, 1.0);
    let air_sky = mu_sky_horizon(dir);

    var cum = mu_cloud_layer_empty();
    if (cloud_cumulus > 0.001) {
        let base = mix(MU_CUMULUS_BASE, 900.0, wet);
        let thick = mix(MU_CUMULUS_THICK, 420.0, wet) + 150.0 * frame.thunder;
        cum = mu_cumulus_layer(origin, dir, max_dist, base, thick, coverage, 14, air_sky);
    }

    var alto = mu_cloud_layer_empty();
    if (cloud_altocumulus > 0.001) {
        let base = mix(MU_ALTO_BASE, 2600.0, wet);
        let thick = mix(MU_ALTO_THICK, 260.0, wet);
        alto = mu_altocumulus_layer(origin, dir, max_dist, base, thick, coverage, 6, air_sky);
    }

    var cir = mu_cloud_layer_empty();
    if (wet < 0.70) { cir = mu_cirrus_layer(origin, dir, max_dist, air_sky); }
    let merged = mu_cloud_composite(cum, alto, cir);
    // Fade the whole deck into the sky in the last few degrees above the
    // horizon: a layer crossed at a grazing angle otherwise ends in a hard
    // dark band, and that band is what made the far water look grey.
    let horizon = smoothstep(0.006, 0.155, abs(dir.y));
    let fade = horizon * horizon;
    return vec4<f32>(merged.rgb * fade, mix(1.0, merged.a, fade));
}


// The sky stage is drawn from the unposed camera rotation, while terrain and
// the post passes use `projection = base * pose * view` (pose is view bobbing
// and the nausea/portal spin). That mismatch makes the sky rotate against the
// world while walking. Recover the pose from the projection and undo it.
fn mu_sky_unpose(dir: vec3<f32>) -> vec3<f32> {
    let ray = (frame.view * vec4<f32>(dir, 0.0)).xyz;
    let p = frame.projection;

    // Rows of the projection's upper 3x3. The base perspective is diagonal in
    // x and y, so each row is one pose row times a scale; normalise it back.
    let r0 = normalize(vec3<f32>(p[0][0], p[1][0], p[2][0]));
    let r1 = normalize(vec3<f32>(p[0][1], p[1][1], p[2][1]));
    let r2 = normalize(vec3<f32>(p[0][2], p[1][2], p[2][2]));

    // Q's columns, for Q^T * ray.
    let c0 = vec3<f32>(r0.x, r1.x, r2.x);
    let c1 = vec3<f32>(r0.y, r1.y, r2.y);
    let c2 = vec3<f32>(r0.z, r1.z, r2.z);
    let posed = vec3<f32>(dot(c0, ray), dot(c1, ray), dot(c2, ray));
    return normalize((frame.view_inverse * vec4<f32>(posed, 0.0)).xyz);
}

// The whole Overworld sky as display-encoded colour. The sky stage always
// draws it in full: with [sky] clouds/sun/stars = false the engine's own sky
// props are gone, so this is the only place they can come from.
fn mu_sky_encoded(dir_in: vec3<f32>, full: bool) -> vec3<f32> {
    let dir = mu_sky_unpose(dir_in);
    var radiance = mu_sky_radiance(dir, 12) * sky_intensity;

    // The reference's atmosphere reads bluer than a straight Rayleigh
    // integral; a small saturation boost gets the deep zenith without a LUT.
    let sky_luma = mu_luma709(radiance);
    radiance = mix(vec3<f32>(sky_luma), radiance, sky_saturation);

    let overcast = mu_sat(frame.rain * 0.8 + frame.thunder * 0.2);
    let grey = vec3<f32>(mu_luma709(radiance)) * vec3<f32>(0.85, 0.9, 1.0);
    radiance = mix(radiance, grey * 0.55, overcast);

    // A little extra blue in the upper dome. A pure Rayleigh integral reads
    // grey-blue on a display; this is the clear-day lift.
    let daylight = smoothstep(-0.10, 0.15, frame.sun_direction.y);
    radiance = radiance + vec3<f32>(0.020, 0.055, 0.150) * daylight
        * (0.35 + 0.65 * mu_sat(dir.y)) * (1.0 - overcast);

    if (full) {
        let sun = frame.sun_direction;
        let moon = frame.moon_direction;
        let clear = 1.0 - overcast;

        // Sun disc. The moon's disc is still drawn by the engine (there is no
        // manifest flag for it), so only its halo is added here.
        let sun_ang = acos(clamp(dot(dir, sun), -1.0, 1.0));
        let sun_disk = 1.0 - smoothstep(0.0180, 0.0220, sun_ang);
        radiance = radiance + mu_sun_color(sun.y) * (sun_disk * 9.0 * clear);
        // A sun-space halo, so part of the glare is anchored to the sun's
        // direction and cannot drift with a cloud passing under it.
        let sun_mu = mu_sat(dot(dir, sun));
        radiance = radiance + mu_sun_color(sun.y)
            * (pow(sun_mu, 512.0) * 1.10 + pow(sun_mu, 64.0) * 0.12)
            * clear * daylight;
        let moon_ang = acos(clamp(dot(dir, moon), -1.0, 1.0));
        let moon_halo = exp(-moon_ang * 18.0) * 0.22 + exp(-moon_ang * 90.0) * 0.55;
        radiance = radiance + vec3<f32>(0.55, 0.66, 0.95)
            * (moon_halo * clear * smoothstep(-0.05, 0.1, moon.y));

        // Stars.
        let night = 1.0 - smoothstep(-0.18, 0.0, sun.y);
        if (night > 0.0 && dir.y > 0.02) {
            let cell = floor(dir * 600.0);
            let h = mu_hash3(cell);
            let star = step(0.9965, h);
            let b = 0.5 + 1.2 * mu_hash3(cell + vec3<f32>(7.0, 3.0, 1.0));
            radiance = radiance + vec3<f32>(0.9, 0.95, 1.0)
                * (star * b * 1.0 * night * clear * smoothstep(0.02, 0.25, dir.y));
        }

        // Clouds are composited in the depth-aware post pass, not here: a sky
        // shader only covers rays above the horizon and would lose the deck
        // when the camera flies above it.
    }

    var encoded = mu_scene_encode(radiance);
    // Dither before the 8-bit frame stores the sky: a smooth gradient over a
    // whole dome is exactly where banding shows.
    let dith = (mu_hash3(floor(dir * 4096.0)) - 0.5) / 255.0;
    encoded = clamp(encoded + vec3<f32>(dith), vec3<f32>(0.0), vec3<f32>(1.0));

    // Horizon haze. This used to mix the whole lower dome toward vanilla's
    // fog colour, which is what turned the horizon into a flat white band.
    // Now it is the atmosphere's own horizon colour, and only the last few
    // degrees take it.
    let horizon = 1.0 - smoothstep(0.0, 0.11, max(dir.y, 0.0));
    let haze = mu_scene_encode(mu_sky_horizon(dir) * 1.04);
    encoded = mix(encoded, haze, horizon * sky_fog_blend);
    encoded = mix(encoded, haze, (1.0 - smoothstep(-0.06, 0.0, dir.y)) * sky_fog_blend * 0.45);
    return encoded;
}
